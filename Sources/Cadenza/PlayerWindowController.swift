import AppKit
import WebKit

enum PlaybackMode: String {
    case audio, video, none
}

final class PlayerWindowController: NSWindowController, NSToolbarDelegate, WKNavigationDelegate,
    WKUIDelegate, WKScriptMessageHandler
{
    static let home = URL(string: "https://music.youtube.com/")!

    // Google's sign-in refuses unidentified embedded browsers, so present as desktop Safari
    // (which is what WKWebView is underneath).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    let webView: WKWebView
    private(set) var mode: PlaybackMode = .none
    private(set) var canSwitchMode = false

    private var modeControl: NSSegmentedControl!
    private var titleObservation: NSKeyValueObservation?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: stay signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        let maxQuality = UserDefaults.standard.bool(forKey: Prefs.maxQuality)
        let source = bridgeScript + "\nwindow.__cadenza.maxQuality = \(maxQuality);"
        config.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Cadenza"
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.02, alpha: 1)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("PlayerWindow")

        super.init(window: window)

        config.userContentController.add(self, name: "cadenza")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = webView

        let toolbar = NSToolbar(identifier: "player")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            let title = view.title ?? ""
            self?.window?.title = title.isEmpty ? "Cadenza" : title
        }

        loadHome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func loadHome() { webView.load(URLRequest(url: Self.home)) }

    /// Calls a function on the injected `window.__cadenza` bridge.
    func run(_ call: String) {
        webView.evaluateJavaScript("window.__cadenza && window.__cadenza.\(call)", completionHandler: nil)
    }

    func setMode(_ newMode: PlaybackMode) {
        guard newMode != .none else { return }
        run("setMode('\(newMode.rawValue)')")
    }

    // MARK: Toolbar

    private static let navItem = NSToolbarItem.Identifier("nav")
    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let modeItem = NSToolbarItem.Identifier("mode")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navItem, Self.reloadItem, .flexibleSpace, Self.modeItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navItem, Self.reloadItem, .flexibleSpace, Self.modeItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.navItem:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("chevron.left", "Back"), symbol("chevron.right", "Forward")],
                selectionMode: .momentary, labels: ["Back", "Forward"],
                target: self, action: #selector(navigate(_:)))
            group.label = "Back/Forward"
            return group
        case Self.reloadItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("arrow.clockwise", "Reload")
            item.label = "Reload"
            item.toolTip = "Reload"
            item.isBordered = true
            item.target = self
            item.action = #selector(reloadPage)
            return item
        case Self.modeItem:
            modeControl = NSSegmentedControl(
                labels: ["Song", "Video"], trackingMode: .selectOne,
                target: self, action: #selector(modeChanged(_:)))
            modeControl.setImage(symbol("music.note", "Song"), forSegment: 0)
            modeControl.setImage(symbol("play.rectangle", "Video"), forSegment: 1)
            modeControl.segmentStyle = .automatic
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = modeControl
            item.label = "Song/Video"
            item.toolTip = "Switch between audio and music video"
            refreshModeControl()
            return item
        default:
            return nil
        }
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    private func refreshModeControl() {
        guard let control = modeControl else { return }
        control.isEnabled = canSwitchMode
        switch mode {
        case .audio: control.selectedSegment = 0
        case .video: control.selectedSegment = 1
        case .none: control.selectedSegment = -1
        }
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { webView.goBack() } else { webView.goForward() }
    }

    @objc private func reloadPage() { webView.reload() }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 1 ? .video : .audio)
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let state = message.body as? [String: Any] else { return }
        mode = PlaybackMode(rawValue: state["mode"] as? String ?? "") ?? .none
        canSwitchMode = (state["canSwitch"] as? Bool ?? false) && mode != .none
        refreshModeControl()

        let quality = state["quality"] as? String ?? ""
        window?.subtitle = mode == .video && !quality.isEmpty ? "Video · \(quality)" : ""
    }

    // MARK: Navigation

    /// Hosts that stay inside the app: the player itself and Google's sign-in.
    private func isInApp(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true } // about:blank, blob:, data:
        if host == "youtube.com" || host.hasSuffix(".youtube.com") { return true }
        let labels = host.split(separator: ".")
        return labels.contains("google") || host.hasSuffix(".googleusercontent.com")
            || host.hasSuffix(".gstatic.com") || host.hasSuffix(".youtube-nocookie.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !isInApp(url) {
            // Artist websites, merch links and the like belong in the real browser.
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // target=_blank links and window.open(): keep in-app pages in this window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInApp(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let err = error as NSError
        // -999: superseded by another navigation; 102: we cancelled it in decidePolicyFor.
        if err.code == NSURLErrorCancelled || (err.domain == "WebKitErrorDomain" && err.code == 102) { return }
        let message = err.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
            <html><body style="background:#050505;color:#eee;font:15px -apple-system;display:flex;\
            flex-direction:column;align-items:center;justify-content:center;height:100vh;margin:0">
            <h2 style="font-weight:600">Can’t reach YouTube Music</h2>
            <p style="color:#999;max-width:420px;text-align:center">\(message)</p>
            <a href="\(Self.home.absoluteString)" style="color:#ff4e45">Try again</a></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // File pickers (e.g. uploading music or a playlist cover).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
