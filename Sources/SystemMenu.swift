import AppKit
import ApplicationServices
import ImageIO
import SwiftUI
import ScreenCaptureKit
import Carbon.HIToolbox

// MARK: - Wallpaper strip (makes Topline look transparent like the real menu bar)

@MainActor
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()
    @Published private(set) var strip: NSImage?
    @Published private(set) var isLight = false
    private var key = ""

    func update(screen: NSScreen, barHeight: CGFloat) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { strip = nil; return }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let k = "\(url.path)|\(mod)|\(screen.frame.size)|\(barHeight)"
        guard k != key else { return }
        key = k
        guard let (img, light) = Self.makeStrip(url: url, screenSize: screen.frame.size, height: barHeight,
                                                scale: screen.backingScaleFactor) else {
            strip = nil
            return
        }
        strip = NSImage(cgImage: img, size: NSSize(width: screen.frame.width, height: barHeight))
        isLight = light
    }

    /// Crops the top `height` points of the wallpaper as macOS draws it (aspect-fill, centered).
    private static func makeStrip(url: URL, screenSize: CGSize, height: CGFloat, scale: CGFloat) -> (CGImage, Bool)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(screenSize.width, screenSize.height) * scale),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = max(screenSize.width / iw, screenSize.height / ih)      // points per image pixel
        let visW = screenSize.width / s, visH = screenSize.height / s
        let rect = CGRect(x: (iw - visW) / 2, y: (ih - visH) / 2, width: visW, height: height / s).integral
        guard let crop = img.cropping(to: rect) else { return nil }
        return (crop, luminance(crop) > 0.62)
    }

    private static func luminance(_ img: CGImage) -> Double {
        let w = 32, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var total = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            total += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
        }
        return total / Double(w * h) / 255
    }
}

// MARK: - Apple menu + front app menus (via Accessibility)

final class AXBox: NSObject {
    let element: AXUIElement
    init(_ e: AXUIElement) { element = e }
}

@MainActor
final class AppMenus: NSObject, ObservableObject {
    static let shared = AppMenus()

    /// Top-level menu titles of the front app. Index 0 = Apple menu, 1 = app name menu, then File, Edit…
    @Published private(set) var titles: [String] = []
    @Published private(set) var trusted = AXIsProcessTrusted()
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var appName = ""
    private var timer: Timer?

    // Menu Search: every command of the active app, flattened ("File › Export › PDF").
    @Published private(set) var searchItems: [MenuHit] = []
    @Published private(set) var searchAppName = ""
    @Published private(set) var searchLoading = false
    private var searchPID: pid_t = 0

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Apps finish building their menus right after activating.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.refresh() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let t = AXIsProcessTrusted()
        if t != trusted { trusted = t }
        guard trusted else { if !titles.isEmpty { titles = [] }; return }
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.5)
            appElement = el
            appPID = app.processIdentifier
            appName = app.localizedName ?? ""
        }
        let new = topItems().map { Self.string($0, kAXTitleAttribute) ?? "" }
        if new != titles { titles = new }
    }

    /// "Allowed but still asking": the saved permission belongs to an older build's signature.
    /// Clear Topline's own entry, then ask again so macOS records the current signature.
    func resetPermission() {
        if let id = Bundle.main.bundleIdentifier {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            try? p.run()
            p.waitUntilExit()
        }
        requestPermission()
    }

    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Shows the front app's menu number `index` (0 = Apple menu) with its top-left at `point` (screen coords).
    func popUp(index: Int, at point: NSPoint) {
        refresh()
        let items = topItems()
        let menu: NSMenu
        if trusted, index < items.count {
            menu = buildMenu(from: items[index], depth: 0)
        } else if index == 0 {
            menu = fallbackAppleMenu()
        } else {
            return
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Reads all menu commands of the app you were just using (call before Topline activates itself).
    func snapshotForSearch() {
        refresh()
        guard trusted else { searchItems = []; return }
        let items = topItems().map { AXRef(element: $0) }
        searchPID = appPID
        searchAppName = appName
        searchLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [MenuHit] = []
            for top in items {
                let title = Self.string(top.element, kAXTitleAttribute) ?? ""
                Self.collect(top.element, path: title.isEmpty ? [] : [title], depth: 0, into: &out)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.searchItems = out
                    self.searchLoading = false
                }
            }
        }
    }

    /// Brings the target app back to the front, then runs the menu command.
    func run(_ hit: MenuHit) {
        let ref = hit.ref
        NSRunningApplication(processIdentifier: searchPID)?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        }
    }

    nonisolated private static func collect(_ item: AXUIElement, path: [String], depth: Int, into out: inout [MenuHit]) {
        guard depth < 4, out.count < 3000, let axMenu = children(item).first else { return }
        for child in children(axMenu) {
            let title = string(child, kAXTitleAttribute) ?? ""
            if title.isEmpty { continue }
            let p = path + [title]
            if let sub = children(child).first, string(sub, kAXRoleAttribute) == kAXMenuRole {
                collect(child, path: p, depth: depth + 1, into: &out)
            } else {
                out.append(MenuHit(path: p, shortcut: shortcut(child),
                                   enabled: (attr(child, kAXEnabledAttribute) as Bool?) ?? true, ref: AXRef(element: child)))
            }
        }
    }

    nonisolated private static func shortcut(_ el: AXUIElement) -> String {
        guard let key = string(el, kAXMenuItemCmdCharAttribute), !key.isEmpty,
              let scalar = key.unicodeScalars.first, scalar.value < 0xF700 else { return "" }
        let mods = (attr(el, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + key.uppercased()
    }

    private func topItems() -> [AXUIElement] {
        guard let appElement, let bar: AXUIElement = Self.attr(appElement, kAXMenuBarAttribute) else { return [] }
        return Self.children(bar)
    }

    private func buildMenu(from item: AXUIElement, depth: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let axMenu = Self.children(item).first else { return menu }
        for child in Self.children(axMenu).prefix(400) {
            let title = Self.string(child, kAXTitleAttribute) ?? ""
            if title.isEmpty {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            let mi = NSMenuItem(title: title, action: #selector(press(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = AXBox(child)
            mi.isEnabled = (Self.attr(child, kAXEnabledAttribute) as Bool?) ?? true
            if let mark = Self.string(child, kAXMenuItemMarkCharAttribute), !mark.isEmpty { mi.state = .on }
            if let key = Self.string(child, kAXMenuItemCmdCharAttribute), key.count == 1,
               let scalar = key.unicodeScalars.first, scalar.value > 0x20, scalar.value < 0xF700 {
                let mods = (Self.attr(child, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0
                var mask: NSEvent.ModifierFlags = []
                if mods & 8 == 0 { mask.insert(.command) }
                if mods & 1 != 0 { mask.insert(.shift) }
                if mods & 2 != 0 { mask.insert(.option) }
                if mods & 4 != 0 { mask.insert(.control) }
                mi.keyEquivalent = key.lowercased()
                mi.keyEquivalentModifierMask = mask
            }
            if depth < 3, let sub = Self.children(child).first, Self.string(sub, kAXRoleAttribute) == kAXMenuRole {
                mi.submenu = buildMenu(from: child, depth: depth + 1)
                mi.action = nil
            }
            menu.addItem(mi)
        }
        return menu
    }

    @objc private func press(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AXBox else { return }
        AXUIElementPerformAction(box.element, kAXPressAction as CFString)
    }

    // Shown before Accessibility access is granted.
    private func fallbackAppleMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add("About This Mac", #selector(aboutMac))
        add("System Settings…", #selector(systemSettings))
        add("Activity Monitor (Force Quit)…", #selector(activityMonitor))
        m.addItem(.separator())
        add("Sleep", #selector(sleepNow))
        add("Lock Screen", #selector(lockScreen))
        m.addItem(.separator())
        add("Show Full Apple & App Menus (grant access)…", #selector(grant))
        return m
    }

    @objc private func aboutMac() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")!)
    }
    @objc private func systemSettings() { launch("/System/Applications/System Settings.app") }
    @objc private func activityMonitor() { launch("/System/Applications/Utilities/Activity Monitor.app") }
    @objc private func sleepNow() { runPmset("sleepnow") }
    @objc private func lockScreen() { runPmset("displaysleepnow") }
    @objc private func grant() { requestPermission() }

    private func runPmset(_ arg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = [arg]
        try? p.run()
    }

    // MARK: AX helpers

    nonisolated static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
    nonisolated static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) }
    nonisolated static func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) ?? [] }
}

struct MenuHit: Identifiable {
    let id = UUID()
    let path: [String]
    let shortcut: String
    let enabled: Bool
    let ref: AXRef
    var title: String { path.last ?? "" }
    var trail: String { path.dropLast().joined(separator: " › ") }
}

// MARK: - Real menu bar icons (Wi-Fi, Control Center, other apps' status items) via Accessibility

/// An AXUIElement that can cross threads (AX calls are thread-safe; the CF type just isn't marked Sendable).
struct AXRef: @unchecked Sendable { let element: AXUIElement }

struct MenuExtra: Identifiable, Equatable {
    let id: String          // stable key: bundle id + identifier/description
    let name: String
    let symbol: String?     // SF Symbol for known system items; nil = use the owning app's icon
    let bundleID: String
    let pid: pid_t
    let x: CGFloat
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    let ref: AXRef
    static func == (a: MenuExtra, b: MenuExtra) -> Bool { a.id == b.id && a.name == b.name && a.x == b.x }
}

@MainActor
final class MenuExtras: ObservableObject {
    static let shared = MenuExtras()
    @Published private(set) var items: [MenuExtra] = []
    @Published var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenMenuExtras") }
    }
    private var timer: Timer?
    private var scanning = false
    /// Real icon artwork, captured from the menu bar (optional; needs Screen Recording).
    @Published private(set) var images: [String: NSImage] = [:]
    private var capturing = false
    private var lastCapture = Date.distantPast

    private init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenMenuExtras")
                     ?? ["com.apple.controlcenter|com.apple.menuextra.clock"])
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    var visible: [MenuExtra] { items.filter { !hidden.contains($0.id) } }

    func refresh() {
        guard AXIsProcessTrusted(), !scanning else { return }
        scanning = true
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != me }
            .map { ($0.processIdentifier, $0.bundleIdentifier ?? "", $0.localizedName ?? "") }
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan(apps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    let changed = found != self.items
                    if changed { self.items = found }
                    if changed || Date().timeIntervalSince(self.lastCapture) > 12 { self.captureIcons() }
                }
            }
        }
    }

    static var realIconsEnabled: Bool { UserDefaults.standard.bool(forKey: "realMenuIcons") }

    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: "realMenuIcons")
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        captureIcons()
    }

    /// Captures the menu bar's own window(s) and cuts out each icon at the position Accessibility reports.
    /// Works both when every status item is its own window (older macOS) and when one system
    /// process draws the whole bar (newer macOS). Our bar covering it doesn't matter: windows are
    /// captured on their own, not from the screen.
    func captureIcons() {
        guard Self.realIconsEnabled, CGPreflightScreenCaptureAccess(), !capturing, !items.isEmpty else {
            if !Self.realIconsEnabled, !images.isEmpty { images = [:] }
            return
        }
        capturing = true
        lastCapture = Date()
        let targets = items.map { (id: $0.id, rect: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
            .filter { $0.rect.width > 0 && $0.rect.height > 0 }
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        Task.detached(priority: .utility) {
            let result = await Self.capture(targets: targets, scale: scale, screenHeight: mainHeight)
            await MainActor.run {
                self.images = result
                self.capturing = false
            }
        }
    }

    nonisolated private static func capture(targets: [(id: String, rect: CGRect)], scale: CGFloat,
                                            screenHeight: CGFloat) async -> [String: NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        let me = ProcessInfo.processInfo.processIdentifier
        // Menu-bar-shaped windows at the top of the main display, at menu bar / status levels.
        let candidates = content.windows.filter {
            $0.frame.minY <= 0.5 && $0.frame.height <= 60 && (23...25).contains($0.windowLayer)
                && $0.owningApplication?.processID != me
        }
        var shots: [CGWindowID: CGImage] = [:]
        var out: [String: NSImage] = [:]
        for t in targets {
            let center = CGPoint(x: t.rect.midX, y: t.rect.midY)
            guard let w = candidates.filter({ $0.frame.contains(center) })
                    .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { continue }
            if shots[w.windowID] == nil {
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                shots[w.windowID] = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
            }
            guard let shot = shots[w.windowID] else { continue }
            let crop = CGRect(x: (t.rect.minX - w.frame.minX) * scale, y: (t.rect.minY - w.frame.minY) * scale,
                              width: t.rect.width * scale, height: t.rect.height * scale).integral
            guard let img = shot.cropping(to: crop), !isBlank(img) else { continue }
            out[t.id] = NSImage(cgImage: img, size: t.rect.size)
        }
        return out
    }

    /// Items macOS hides (e.g. behind the notch) capture as empty pixels — fall back to symbols for those.
    nonisolated private static func isBlank(_ img: CGImage) -> Bool {
        let w = 16, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return true }
        return !stride(from: 3, to: px.count, by: 4).contains { px[$0] > 40 }
    }

    func press(_ extra: MenuExtra) {
        let ref = extra.ref
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        }
    }

    nonisolated private static func scan(_ apps: [(pid_t, String, String)]) -> [MenuExtra] {
        var out: [MenuExtra] = []
        for (pid, bundle, appName) in apps {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let bar: AXUIElement = AppMenus.attr(app, "AXExtrasMenuBar") else { continue }
            for (i, el) in AppMenus.children(bar).enumerated() {
                let ident = AppMenus.string(el, "AXIdentifier") ?? ""
                let desc = AppMenus.string(el, kAXDescriptionAttribute) ?? AppMenus.string(el, kAXTitleAttribute) ?? ""
                var p = CGPoint.zero, size = CGSize.zero
                if let v: AXValue = AppMenus.attr(el, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
                if let v: AXValue = AppMenus.attr(el, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
                let x = p.x
                let key = "\(bundle)|\(ident.isEmpty ? (desc.isEmpty ? String(i) : desc) : ident)"
                out.append(MenuExtra(id: key, name: desc.isEmpty ? appName : desc, symbol: systemSymbol(bundle: bundle, ident, desc),
                                     bundleID: bundle, pid: pid, x: x, y: p.y, width: size.width, height: size.height,
                                     ref: AXRef(element: el)))
            }
        }
        return out.sorted { $0.x < $1.x }
    }

    /// SF Symbols for Apple's own menu bar items (their real icons can't be read without Screen Recording).
    /// Third-party items return nil and are drawn with their app's icon.
    nonisolated private static func systemSymbol(bundle: String, _ ident: String, _ desc: String) -> String? {
        guard bundle.hasPrefix("com.apple") else { return nil }
        let s = (ident + " " + desc).lowercased()
        let map: [(String, String)] = [
            ("wifi", "wifi"), ("wi‑fi", "wifi"), ("wi-fi", "wifi"),
            ("bluetooth", "dot.radiowaves.left.and.right"),
            ("controlcenter", "switch.2"), ("control center", "switch.2"),
            ("battery", "battery.75"), ("sound", "speaker.wave.2.fill"), ("volume", "speaker.wave.2.fill"),
            ("focus", "moon.fill"), ("spotlight", "magnifyingglass"), ("siri", "mic.fill"),
            ("nowplaying", "play.fill"), ("now playing", "play.fill"), ("display", "sun.max.fill"),
            ("screenmirroring", "rectangle.on.rectangle"), ("screen mirroring", "rectangle.on.rectangle"),
            ("airdrop", "airplayaudio"), ("keyboardbrightness", "light.max"), ("textinput", "keyboard"),
            ("user", "person.crop.circle"), ("clock", "clock"), ("timemachine", "clock.arrow.circlepath"),
            ("vpn", "network.badge.shield.half.filled"), ("weather", "cloud.sun.fill"),
            ("stage", "squares.leading.rectangle"),
        ]
        return map.first { s.contains($0.0) }?.1 ?? "circle.grid.2x2"
    }
}

// MARK: - Global hotkey (⌃⌥Space → Menu Search) via Carbon, no extra permission needed

@MainActor
enum GlobalHotkey {
    static var onPress: () -> Void = {}
    private static var hotKey: EventHotKeyRef?
    private static var installed = false

    static func sync() {
        let on = UserDefaults.standard.object(forKey: "menuSearchHotkey") as? Bool ?? true
        if on, hotKey == nil {
            if !installed {
                installed = true
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.onPress() } }
                    return noErr
                }, 1, &spec, nil, nil)
            }
            let id = EventHotKeyID(signature: OSType(0x544F_504C), id: 1)   // "TOPL"
            RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        } else if !on, let hk = hotKey {
            UnregisterEventHotKey(hk)
            hotKey = nil
        }
    }
}

/// Spotlight-style floating panel for Menu Search, opened by the hotkey.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuSearchPanel {
    static let shared = MenuSearchPanel()
    private var panel: KeyablePanel?

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        AppMenus.shared.snapshotForSearch()   // read the frontmost app's menus before we take focus
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .modalPanel
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        let host = NSHostingView(rootView:
            MenuSearchView(onDone: { [weak self] in self?.close() })
                .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .frame(width: 460, height: 420, alignment: .top))
        p.contentView = host
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 230, y: f.maxY - 420 - f.height * 0.12))
        }
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
