import AppKit
import SwiftUI
import WebKit

final class PlayerWindowController: NSWindowController, NSToolbarDelegate, WKNavigationDelegate,
    WKUIDelegate, WKScriptMessageHandler
{
    static let home = URL(string: "https://music.youtube.com/")!

    // Google's sign-in refuses unidentified embedded browsers, so present as desktop Safari
    // (which is what WKWebView is underneath).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    let webView: WKWebView
    let lyrics = LyricsModel()

    private let lyricsPanel: NSView
    private var webTrailingToPanel: NSLayoutConstraint!
    private var webTrailingToEdge: NSLayoutConstraint!
    private var titleObservation: NSKeyValueObservation?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: stay signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        let audioOnly = UserDefaults.standard.bool(forKey: Prefs.audioOnly)
        let source = bridgeScript + "\nwindow.__cadenza.audioOnly = \(audioOnly);"
        config.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // macOS refuses passkeys in an embedded web view, but the page still sees the WebAuthn API,
        // so Google picks the passkey step and it fails ("Something went wrong… Bluetooth").
        // Hiding the API on Google's sign-in pages makes Google offer password / phone prompt instead.
        let noPasskeys = """
            if (/(^|\\.)google\\.[a-z.]+$/.test(location.hostname)) {
              try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
              try { Object.defineProperty(Navigator.prototype, 'credentials', { get: () => undefined, configurable: true }); } catch (e) {}
            }
            """
        config.userContentController.addUserScript(
            WKUserScript(source: noPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false))

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

        lyricsPanel = NSHostingView(rootView: LyricsView(model: lyrics))

        super.init(window: window)

        lyrics.onSeek = { [weak self] seconds in self?.run("seek(\(seconds))") }

        config.userContentController.add(self, name: "cadenza")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        lyricsPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(lyricsPanel)
        webTrailingToPanel = webView.trailingAnchor.constraint(equalTo: lyricsPanel.leadingAnchor)
        webTrailingToEdge = webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            lyricsPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lyricsPanel.topAnchor.constraint(equalTo: container.topAnchor),
            lyricsPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            lyricsPanel.widthAnchor.constraint(equalToConstant: 340),
        ])
        window.contentView = container
        applyLyricsVisibility()

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

    var lyricsVisible: Bool { UserDefaults.standard.bool(forKey: Prefs.showLyrics) }

    @objc func toggleLyrics() {
        UserDefaults.standard.set(!lyricsVisible, forKey: Prefs.showLyrics)
        applyLyricsVisibility()
    }

    private func applyLyricsVisibility() {
        let show = lyricsVisible
        lyricsPanel.isHidden = !show
        webTrailingToEdge.isActive = !show
        webTrailingToPanel.isActive = show
    }

    func signIn() {
        webView.load(URLRequest(url: URL(string:
            "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!))
    }

    // MARK: Toolbar

    private static let navItem = NSToolbarItem.Identifier("nav")
    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let lyricsItem = NSToolbarItem.Identifier("lyrics")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navItem, Self.reloadItem, .flexibleSpace, Self.lyricsItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navItem, Self.reloadItem, .flexibleSpace, Self.lyricsItem]
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
        case Self.lyricsItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("quote.bubble", "Lyrics")
            item.label = "Lyrics"
            item.toolTip = "Show or hide lyrics"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleLyrics)
            return item
        default:
            return nil
        }
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { webView.goBack() } else { webView.goForward() }
    }

    @objc private func reloadPage() { webView.reload() }

    // MARK: Bridge

    /// YouTube audio format ids ("itags") for the streams the web player uses.
    private static let audioFormats = [
        "139": "AAC 48 kbps", "140": "AAC 128 kbps", "141": "AAC 256 kbps",
        "249": "Opus 50 kbps", "250": "Opus 70 kbps", "251": "Opus 160 kbps", "774": "Opus 256 kbps",
    ]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "time":
            if body["id"] as? String == lyrics.track.id, let t = body["t"] as? Double { lyrics.setTime(t) }
        case "track":
            if body["ad"] as? Bool == true { return } // keep the song's lyrics up during an ad
            lyrics.setTrack(Track(
                id: body["id"] as? String ?? "",
                title: body["title"] as? String ?? "",
                artist: body["artist"] as? String ?? "",
                album: body["album"] as? String ?? "",
                duration: body["duration"] as? Double ?? 0))
            let afmt = body["afmt"] as? String ?? ""
            window?.subtitle = afmt.isEmpty ? "" : (Self.audioFormats[afmt] ?? "Audio format \(afmt)")
        default:
            break
        }
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
