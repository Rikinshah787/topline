import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsWindowController()
    private let welcome = WelcomeWindowController()
    private var ticker: TickerController?
    private var folder: FolderController?
    private var bar: BarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        BarActions.openSettings = { [weak self] in self?.settings.show() }
        syncMenuBarItems()
        bar = BarController()
        GlobalHotkey.onPress = { MenuSearchPanel.shared.toggle() }
        GlobalHotkey.sync()
        QuoteStore.shared.sync(force: true)

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncMenuBarItems() } }   // deferred: never re-enter layout
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            welcome.show()
        }
    }

    /// Double-clicking the app in Finder while it's running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    /// Creates / removes the macOS menu bar ticker and folder as the user toggles them.
    private func syncMenuBarItems() {
        // Order matters on first launch: ticker ends up rightmost, then folder button, then divider.
        if Prefs.menuTicker, ticker == nil {
            ticker = TickerController(openSettings: { [weak self] in self?.settings.show() })
        } else if !Prefs.menuTicker, let t = ticker {
            t.teardown(); ticker = nil
        }
        if Prefs.menuFolder, folder == nil {
            folder = FolderController(openSettings: { [weak self] in self?.settings.show() })
        } else if !Prefs.menuFolder, let f = folder {
            f.teardown(); folder = nil
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon
    app.run()
}
