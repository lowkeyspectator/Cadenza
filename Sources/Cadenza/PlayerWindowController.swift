import AppKit
import SwiftUI
import WebKit

/// Owns the window. The interface is native (SwiftUI); a WKWebView running the official
/// YouTube Music web player sits underneath it as the audio and data engine, and is brought
/// forward only for signing in or changing account settings ("web mode").
@MainActor
final class PlayerWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, Engine
{
    static let home = URL(string: "https://music.youtube.com/")!
    private static let webBarHeight: CGFloat = 52

    // Google's sign-in refuses unidentified embedded browsers, so present as desktop Safari
    // (which is what WKWebView is underneath).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    let webView: WKWebView
    let model = AppModel()

    private var nativeHost: NSView!
    private var webBarHost: NSView!
    private var signingIn = false
    private var observers: [Any] = []

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: stay signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
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
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Cadenza"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 860, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)

        model.engine = self
        config.userContentController.add(self, name: "cadenza")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // The web player stays in the window (WebKit pauses media for detached views) but is
        // covered by the native interface unless web mode is on.
        nativeHost = NSHostingView(rootView: RootView(model: model))
        webBarHost = NSHostingView(rootView: WebModeBar(model: model))
        let container = NSView()
        for view in [webView, nativeHost!, webBarHost!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.webBarHeight),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webBarHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webBarHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webBarHost.topAnchor.constraint(equalTo: container.topAnchor),
            webBarHost.heightAnchor.constraint(equalToConstant: Self.webBarHeight),
            nativeHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nativeHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nativeHost.topAnchor.constraint(equalTo: container.topAnchor),
            nativeHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        installKeyHandling()
        observers.append(model.$webMode.sink { [weak self] on in self?.applyWebMode(on) })
        webView.load(URLRequest(url: Self.home))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyWebMode(_ on: Bool) {
        webBarHost.isHidden = !on
        if nativeHost.isHidden != on {
            // Cross-fade between the native interface and the web player.
            nativeHost.isHidden = false
            let host = nativeHost!
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                host.animator().alphaValue = on ? 0 : 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { host.isHidden = self?.model.webMode ?? false }
            })
        }
        if !on { signingIn = false }
        // Leaving a Google page behind would leave the engine without a player.
        if !on, let host = webView.url?.host, !host.hasSuffix("music.youtube.com") { reloadPlayer() }
    }

    // MARK: Engine

    func fetch(_ call: String, _ arguments: [String: Any]) async throws -> Data {
        var lastError: Error = URLError(.cannotConnectToHost)
        // The player page may be mid-load (launch, after sign-in, after a fallback navigation),
        // so wait for it and retry rather than surfacing a transient failure.
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 700_000_000) }
            guard await bridgeIsReady() else { lastError = URLError(.timedOut); continue }
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return JSON.stringify(await window.__cadenza.\(call))",
                    arguments: arguments, in: nil, contentWorld: .page)
                guard let json = result as? String else { throw URLError(.cannotParseResponse) }
                return Data(json.utf8)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func bridgeIsReady() async -> Bool {
        let probe = "!!(window.__cadenza && window.__cadenza.browse && window.ytcfg && window.ytcfg.get('INNERTUBE_CONTEXT'))"
        for _ in 0..<40 { // up to ~10 s
            if Task.isCancelled { return false }
            if !model.webMode, !webView.isLoading, let host = webView.url?.host,
               !host.hasSuffix("music.youtube.com") {
                reloadPlayer() // stranded on a sign-in page with the web player hidden
            }
            if (try? await webView.evaluateJavaScript(probe)) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Puts the cursor in the sidebar search field.
    func focusSearch() {
        if model.webMode { model.webMode = false }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        if let field = find(nativeHost) { window?.makeFirstResponder(field) }
    }

    /// Space toggles playback, as in Music, unless the user is typing or using the web player.
    private func installKeyHandling() {
        observers.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !self.model.webMode,
                  event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(self.window?.firstResponder is NSText) else { return event }
            self.model.playPause()
            return nil
        } as Any)
    }

    /// Calls a function on the injected `window.__cadenza` bridge.
    func run(_ call: String) {
        webView.evaluateJavaScript("window.__cadenza && window.__cadenza.\(call)", completionHandler: nil)
    }

    func openSignIn() {
        signingIn = true
        webView.load(URLRequest(url: URL(string:
            "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!))
    }

    func reloadPlayer() { webView.load(URLRequest(url: Self.home)) }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "time":
            if let id = body["id"] as? String, let t = body["t"] as? Double { model.playerTime(id: id, t) }
        case "track":
            model.playerReported(body)
            // Sign-in finished: back on YouTube Music with an account.
            if signingIn, body["loggedIn"] as? Bool == true { model.webMode = false }
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
