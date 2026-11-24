import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: PlayerWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Prefs.audioOnly: true, Prefs.showLyrics: true, Prefs.menuBarPlayer: true])
        controller = PlayerWindowController()
        NSApp.mainMenu = buildMenu()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep playing with the window closed; clicking the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller.showMain() }
        return true
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Cadenza"

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        item(appMenu, "Sign In to YouTube Music…", #selector(signIn), "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: name, to: main)

        // Standard Edit menu so copy/paste and typing shortcuts work in the sign-in form and search.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        item(edit, "Search", #selector(search), "f")
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        item(view, "Back", #selector(goBack), "[")
        item(view, "Forward", #selector(goForward), "]")
        item(view, "Home", #selector(goHome), "H", [.command, .shift])
        item(view, "Reload", #selector(reload), "r")
        view.addItem(.separator())
        let sidebar = item(view, "Show Sidebar", #selector(toggleSidebar), "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        item(view, "Show Lyrics", #selector(toggleLyrics), "l")
        item(view, "Show Player in Menu Bar", #selector(toggleMenuBarPlayer), "")
        item(view, "Show Web Player", #selector(toggleWebPlayer), "W", [.command, .shift])
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        add(view, titled: "View", to: main)

        let playback = NSMenu(title: "Playback")
        item(playback, "Play/Pause", #selector(playPause), "p")
        item(playback, "Next", #selector(nextTrack), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        item(playback, "Previous", #selector(previousTrack), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        playback.addItem(.separator())
        item(playback, "Audio Only (No Video)", #selector(toggleAudioOnly), "")
        add(playback, titled: "Playback", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item(window, "Cadenza", #selector(showPlayer), "0")
        item(window, "Switch to MiniPlayer", #selector(toggleMiniPlayer), "M", [.command, .shift])
        let sizes = NSMenu(title: "MiniPlayer Size")
        for size in MiniPlayerSize.allCases {
            let entry = item(sizes, size.title, #selector(setMiniPlayerSize(_:)), "")
            entry.tag = size.rawValue
        }
        let sizesItem = NSMenuItem(title: "MiniPlayer Size", action: nil, keyEquivalent: "")
        sizesItem.submenu = sizes
        window.addItem(sizesItem)
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAudioOnly):
            menuItem.state = UserDefaults.standard.bool(forKey: Prefs.audioOnly) ? .on : .off
            return true
        case #selector(toggleLyrics):
            menuItem.state = controller.model.showLyrics ? .on : .off
            return true
        case #selector(toggleSidebar):
            menuItem.state = controller.model.sidebarHidden ? .off : .on
            return true
        case #selector(toggleMenuBarPlayer):
            menuItem.state = controller.menuBarPlayerEnabled ? .on : .off
            return true
        case #selector(toggleMiniPlayer):
            menuItem.title = controller.isMiniPlayer ? "Switch from MiniPlayer" : "Switch to MiniPlayer"
            return true
        case #selector(toggleWebPlayer):
            menuItem.state = controller.model.webMode ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Actions

    @objc private func goBack() { controller.model.goBack() }
    @objc private func goForward() { controller.model.goForward() }
    @objc private func goHome() { controller.model.open(.home) }
    @objc private func reload() { controller.model.reload() }
    @objc private func playPause() { controller.model.playPause() }
    @objc private func nextTrack() { controller.model.next() }
    @objc private func previousTrack() { controller.model.previous() }
    @objc private func toggleLyrics() { controller.model.toggleLyrics() }
    @objc private func search() { controller.focusSearch() }
    @objc private func toggleWebPlayer() { controller.model.webMode.toggle() }
    @objc private func signIn() { controller.model.signIn() }
    @objc private func showPlayer() { controller.showMain() }
    @objc private func toggleSidebar() { controller.model.toggleSidebar() }
    @objc private func toggleMenuBarPlayer() { controller.toggleMenuBarPlayer() }
    @objc private func toggleMiniPlayer() { controller.toggleMiniPlayer() }
    @objc private func setMiniPlayerSize(_ sender: NSMenuItem) {
        if let size = MiniPlayerSize(rawValue: sender.tag) { controller.setMiniPlayerSize(size) }
    }

    /// Dock icon menu: transport controls without bringing the app forward.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let now = controller.model.now
        if !now.isEmpty {
            menu.addItem(withTitle: "\(now.title) — \(now.artist)", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        item(menu, now.playing ? "Pause" : "Play", #selector(playPause), "")
        item(menu, "Next", #selector(nextTrack), "")
        item(menu, "Previous", #selector(previousTrack), "")
        menu.addItem(.separator())
        item(menu, controller.isMiniPlayer ? "Switch from MiniPlayer" : "Switch to MiniPlayer",
             #selector(toggleMiniPlayer), "")
        return menu
    }

    @objc private func toggleAudioOnly() {
        let on = !UserDefaults.standard.bool(forKey: Prefs.audioOnly)
        UserDefaults.standard.set(on, forKey: Prefs.audioOnly)
        controller.run("setAudioOnly(\(on))")
    }
}

enum Prefs {
    static let audioOnly = "audioOnly"
    static let showLyrics = "showLyrics"
    static let sidebarHidden = "sidebarHidden"
    static let menuBarPlayer = "menuBarPlayer"
}
