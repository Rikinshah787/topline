import AppKit
import UniformTypeIdentifiers

// MARK: - Model

enum Zone: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum WidgetType: String, Codable, CaseIterable, Identifiable {
    case appleMenu, appMenus, frontApp, clock, date, battery, cpu, memory, network, stock, menuExtras, menuSearch, keepAwake, peek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleMenu: "Apple Menu"
        case .appMenus: "App Menus (File, Edit…)"
        case .frontApp: "Active App Name"
        case .peek: "Show macOS Menu Bar (peek)"
        case .menuExtras: "Menu Bar Icons (Wi-Fi, Control Center…)"
        case .menuSearch: "Menu Search (run any menu command)"
        case .keepAwake: "Keep Awake"
        case .network: "Network Speed"
        case .clock: "Clock"
        case .date: "Date"
        case .battery: "Battery"
        case .cpu: "CPU Usage"
        case .memory: "Memory Usage"
        case .stock: "Stock Price…"
        }
    }
    var symbol: String {
        switch self {
        case .appleMenu: "apple.logo"
        case .appMenus: "menubar.rectangle"
        case .frontApp: "macwindow"
        case .peek: "menubar.arrow.up.rectangle"
        case .menuExtras: "switch.2"
        case .menuSearch: "magnifyingglass"
        case .keepAwake: "cup.and.saucer"
        case .network: "arrow.up.arrow.down"
        case .clock: "clock"
        case .date: "calendar"
        case .battery: "battery.75"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .stock: "chart.line.uptrend.xyaxis"
        }
    }
}

struct BarItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: Kind

    enum Kind: Codable, Equatable {
        case app(path: String)
        case file(path: String)
        case folder(name: String, symbol: String, items: [BarItem])
        case widget(type: WidgetType, symbol: String?)
        case spacer
        case divider
    }

    static func from(url: URL) -> BarItem {
        url.pathExtension.lowercased() == "app" ? BarItem(kind: .app(path: url.path)) : BarItem(kind: .file(path: url.path))
    }

    /// Only apps and files can live inside a folder/tray.
    var canGoInFolder: Bool {
        switch kind {
        case .app, .file: true
        default: false
        }
    }

    var displayName: String {
        switch kind {
        case .app(let p), .file(let p):
            let n = FileManager.default.displayName(atPath: p)
            return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        case .folder(let n, _, _): return n
        case .widget(let t, let s): return t == .stock ? (s ?? "Stock") : t.title
        case .spacer: return "Spacer"
        case .divider: return "Divider"
        }
    }
}

struct BarLayout: Codable, Equatable {
    var left: [BarItem] = []
    var center: [BarItem] = []
    var right: [BarItem] = []

    subscript(_ z: Zone) -> [BarItem] {
        get { switch z { case .left: left; case .center: center; case .right: right } }
        set { switch z { case .left: left = newValue; case .center: center = newValue; case .right: right = newValue } }
    }

    func find(_ id: UUID) -> BarItem? {
        for z in Zone.allCases {
            for item in self[z] {
                if item.id == id { return item }
                if case .folder(_, _, let items) = item.kind, let hit = items.first(where: { $0.id == id }) { return hit }
            }
        }
        return nil
    }

    /// Removes an item from anywhere (bar zones or inside folders) and returns it.
    mutating func take(_ id: UUID) -> BarItem? {
        for z in Zone.allCases {
            if let i = self[z].firstIndex(where: { $0.id == id }) { return self[z].remove(at: i) }
            for (fi, f) in self[z].enumerated() {
                if case .folder(let n, let s, var items) = f.kind, let i = items.firstIndex(where: { $0.id == id }) {
                    let hit = items.remove(at: i)
                    self[z][fi].kind = .folder(name: n, symbol: s, items: items)
                    return hit
                }
            }
        }
        return nil
    }

    mutating func update(_ id: UUID, _ change: (inout BarItem) -> Void) {
        for z in Zone.allCases {
            if let i = self[z].firstIndex(where: { $0.id == id }) {
                var item = self[z][i]; change(&item); self[z][i] = item
                return
            }
        }
    }

    /// Puts `item` before/after `target` (bar item or tray item), into `folder`, or at the end of `zone`.
    mutating func place(_ item: BarItem, zone: Zone, target: UUID?, after: Bool, folder: UUID?) {
        if let fid = folder, item.canGoInFolder, item.id != fid {
            for z in Zone.allCases {
                if let fi = self[z].firstIndex(where: { $0.id == fid }),
                   case .folder(let n, let s, var items) = self[z][fi].kind {
                    items.append(item)
                    self[z][fi].kind = .folder(name: n, symbol: s, items: items)
                    return
                }
            }
        }
        let t = folder ?? target
        if let t {
            for z in Zone.allCases {
                if let i = self[z].firstIndex(where: { $0.id == t }) {
                    self[z].insert(item, at: after ? i + 1 : i)
                    return
                }
                // Target is an item inside a tray → reorder within that tray.
                if item.canGoInFolder {
                    for (fi, f) in self[z].enumerated() {
                        if case .folder(let n, let s, var items) = f.kind, let i = items.firstIndex(where: { $0.id == t }) {
                            items.insert(item, at: after ? i + 1 : i)
                            self[z][fi].kind = .folder(name: n, symbol: s, items: items)
                            return
                        }
                    }
                }
            }
        }
        self[zone].append(item)
    }
}

// MARK: - Presets

enum BarPreset: String, CaseIterable, Identifiable {
    case minimal, balanced, everything
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .minimal: "Menus, your apps, one stock, icons and the time. Like macOS, but better."
        case .balanced: "Adds a second stock, Menu Search and Keep Awake."
        case .everything: "Every stock you track plus network, CPU and battery."
        }
    }
    var maxStocks: Int {
        switch self { case .minimal: 1; case .balanced: 2; case .everything: .max }
    }
    var widgets: [WidgetType] {
        switch self {
        case .minimal: [.menuExtras, .date, .clock]
        case .balanced: [.menuSearch, .keepAwake, .menuExtras, .date, .clock]
        case .everything: [.network, .cpu, .battery, .menuSearch, .keepAwake, .menuExtras, .date, .clock]
        }
    }
}

extension BarLayout {
    /// The same apps, files, folders and stocks, with the preset's widgets in the macOS order.
    func applying(_ preset: BarPreset) -> BarLayout {
        func isMine(_ i: BarItem) -> Bool {
            switch i.kind { case .app, .file, .folder: true; default: false }
        }
        func widget(_ t: WidgetType, _ s: String? = nil) -> BarItem { BarItem(kind: .widget(type: t, symbol: s)) }
        var stocks: [String] = []
        for item in left + center + right {
            if case .widget(.stock, let s?) = item.kind, !stocks.contains(s) { stocks.append(s) }
        }
        if stocks.isEmpty { stocks = ["AAPL"] }
        let mine = right.filter(isMine)
        var l = BarLayout()
        l.left = [widget(.appleMenu), widget(.appMenus)] + left.filter(isMine)
        l.center = center.filter(isMine)
        l.right = mine + (mine.isEmpty ? [] : [BarItem(kind: .divider)])
            + stocks.prefix(preset.maxStocks).map { widget(.stock, $0) }
            + preset.widgets.map { widget($0) }
        return l
    }
}

// MARK: - Store

@MainActor
final class BarStore: ObservableObject {
    static let shared = BarStore()

    @Published var layout: BarLayout {
        didSet {
            guard layout != oldValue else { return }
            save()
            QuoteStore.shared.sync()
        }
    }

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var fileURL: URL {
        let dir = supportDir.appendingPathComponent("Topline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bar.json")
    }

    private init() {
        // Build the final layout in a local first: assigning `layout` again inside init would run didSet,
        // which touches BarStore.shared while it's still being created.
        var l: BarLayout
        var upgraded = false
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(BarLayout.self, from: data) {
            l = saved
        } else {
            l = Self.defaultLayout()
            upgraded = true
        }
        // One-time tidy for layouts made before presets existed: keep apps, folders and stocks, trim widgets.
        if !UserDefaults.standard.bool(forKey: "tidiedLayout") {
            UserDefaults.standard.set(true, forKey: "tidiedLayout")
            if !upgraded { l = l.applying(.minimal); upgraded = true }
        }
        layout = l
        if upgraded { save() }
    }

    static func defaultLayout() -> BarLayout {
        let tray = ["/Applications/Safari.app", "/System/Applications/Notes.app", "/System/Applications/Calendar.app",
                    "/System/Applications/Utilities/Terminal.app", "/System/Applications/System Settings.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }.map { BarItem(kind: .app(path: $0)) }
        let base = BarLayout(right: [BarItem(kind: .folder(name: "Apps", symbol: "square.grid.2x2.fill", items: tray))])
        return base.applying(.minimal)
    }

    /// Rebuilds the bar's widgets from a preset. Your apps, files, folders and stocks are kept.
    func apply(_ preset: BarPreset) {
        layout = layout.applying(preset)
        UserDefaults.standard.set(preset.rawValue, forKey: "barPreset")
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(layout) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    func reset() {
        layout = Self.defaultLayout()
        UserDefaults.standard.set(BarPreset.minimal.rawValue, forKey: "barPreset")
    }

    // MARK: Edits

    func remove(_ id: UUID) {
        var l = layout; _ = l.take(id); layout = l
    }

    func moveToZone(_ id: UUID, _ zone: Zone) {
        var l = layout
        guard let item = l.take(id) else { return }
        l[zone].append(item)
        layout = l
    }

    func add(_ item: BarItem, zone: Zone) {
        var l = layout; l[zone].append(item); layout = l
    }

    func addFolder(zone: Zone) {
        guard let name = promptText(title: "New Folder", message: "Name your tray:", initial: "Folder"), !name.isEmpty else { return }
        add(BarItem(kind: .folder(name: name, symbol: "folder.fill", items: [])), zone: zone)
    }

    func addWidget(_ type: WidgetType, zone: Zone) {
        if type == .stock {
            StockPicker.pick { s in self.add(BarItem(kind: .widget(type: .stock, symbol: s.uppercased())), zone: zone) }
        } else {
            add(BarItem(kind: .widget(type: type, symbol: nil)), zone: zone)
        }
    }

    /// Pick apps and put them inside a folder / tray.
    func chooseApps(intoFolder folderID: UUID) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Folder"
        guard panel.runModal() == .OK else { return }
        var l = layout
        for url in panel.urls { l.place(.from(url: url), zone: .right, target: nil, after: true, folder: folderID) }
        layout = l
    }

    func chooseApps(zone: Zone) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Bar"
        guard panel.runModal() == .OK else { return }
        var l = layout
        for url in panel.urls { l[zone].append(.from(url: url)) }
        layout = l
    }

    func renameFolder(_ id: UUID) {
        guard case .folder(let n, let s, let items)? = layout.find(id)?.kind,
              let new = promptText(title: "Rename Folder", message: "New name:", initial: n), !new.isEmpty else { return }
        var l = layout
        l.update(id) { $0.kind = .folder(name: new, symbol: s, items: items) }
        layout = l
    }

    func setFolderSymbol(_ id: UUID, _ symbol: String) {
        guard case .folder(let n, _, let items)? = layout.find(id)?.kind else { return }
        var l = layout
        l.update(id) { $0.kind = .folder(name: n, symbol: symbol, items: items) }
        layout = l
    }

    func changeStockSymbol(_ id: UUID) {
        guard case .widget(.stock, let s)? = layout.find(id)?.kind else { return }
        StockPicker.pick(title: "Replace \(s ?? "Stock")") { new in
            var l = self.layout
            l.update(id) { $0.kind = .widget(type: .stock, symbol: new.uppercased()) }
            self.layout = l
        }
    }

    /// Every stock symbol on the bar, in bar order.
    var stockSymbols: [(id: UUID, symbol: String)] {
        Zone.allCases.flatMap { layout[$0] }.compactMap {
            if case .widget(.stock, let s?) = $0.kind { return ($0.id, s) } else { return nil }
        }
    }

    // MARK: Drag & drop

    /// Handles drops of Finder files/apps (file URLs) and internal bar items ("baritem:<uuid>" strings).
    func accept(_ providers: [NSItemProvider], zone: Zone, target: UUID?, after: Bool, folder: UUID?) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            var l = self.layout
                            l.place(.from(url: url), zone: zone, target: target, after: after, folder: folder)
                            self.layout = l
                        }
                    }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { str, _ in
                    guard let str, str.hasPrefix("baritem:"), let id = UUID(uuidString: String(str.dropFirst(8))) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.move(id, zone: zone, target: target, after: after, folder: folder) }
                    }
                }
            }
        }
    }

    private func move(_ id: UUID, zone: Zone, target: UUID?, after: Bool, folder: UUID?) {
        guard id != target, id != folder else { return }
        var l = layout
        guard let item = l.take(id) else { return }
        l.place(item, zone: zone, target: target, after: after, folder: folder)
        layout = l
    }
}

// MARK: - Helpers

@MainActor
func promptText(title: String, message: String, initial: String) -> String? {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    private static var bundleIDs: [String: String] = [:]

    static func icon(_ path: String) -> NSImage {
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons[path] = i
        return i
    }

    static func bundleID(_ path: String) -> String? {
        if let b = bundleIDs[path] { return b.isEmpty ? nil : b }
        let b = Bundle(path: path)?.bundleIdentifier
        bundleIDs[path] = b ?? ""
        return b
    }
}

let folderSymbolChoices = [
    "folder.fill", "square.grid.2x2.fill", "tray.full.fill", "star.fill", "heart.fill", "briefcase.fill",
    "hammer.fill", "terminal.fill", "paintbrush.fill", "gamecontroller.fill", "music.note", "globe",
    "bubble.left.and.bubble.right.fill", "doc.fill", "bolt.fill", "sparkles",
]
