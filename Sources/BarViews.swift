import SwiftUI
import UniformTypeIdentifiers

let barDropTypes: [UTType] = [.fileURL, .utf8PlainText, .plainText]

@MainActor
enum BarActions {
    static var openSettings: () -> Void = {}
    static var peek: () -> Void = {}
}

/// Converts a SwiftUI global frame inside the bar into the screen point just below it (for NSMenu popups).
@MainActor
func screenPointBelow(_ f: CGRect) -> NSPoint {
    let p = BarUI.shared.panelFrame
    return NSPoint(x: p.minX + f.minX, y: p.maxY - f.maxY)
}

/// Shared UI state for the bar (which popover is open, notch size).
@MainActor
final class BarUI: ObservableObject {
    static let shared = BarUI()
    @Published var openPopover: UUID?
    @Published var notchWidth: CGFloat = 0
    var panelFrame: CGRect = .zero
    @Published var menuBarAutoHides = false
}

// MARK: - Root

struct BarRootView: View {
    @ObservedObject private var store = BarStore.shared
    @ObservedObject private var ui = BarUI.shared
    @ObservedObject private var wallpaper = Wallpaper.shared
    @AppStorage("barStyle") private var style = "full"
    @AppStorage("barPosition") private var position = "replace"
    @AppStorage("barBackground") private var background = "macos"
    @AppStorage("barColor") private var colorHex = "#1C1C28"
    @AppStorage("barOpacity") private var opacity = 0.92

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backgroundView
                Group {
                    if ui.notchWidth > 0 {
                        // Camera notch in the middle: left side (+ center items) | notch | right side.
                        let side = max(0, (geo.size.width - ui.notchWidth) / 2 - 14)
                        HStack(spacing: 0) {
                            HStack(spacing: 2) { zone(.left); zone(.center) }
                                .frame(width: side, alignment: .leading).clipped()
                            Spacer(minLength: 0)
                            FitZone(zone: .right, available: side).frame(width: side, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                    } else {
                        HStack(spacing: 2) {
                            zone(.left)
                            Spacer(minLength: 12)
                            FitZone(zone: .right, available: max(0, (geo.size.width - 16) * 0.6))
                        }
                        .padding(.horizontal, 8)
                        zone(.center)
                    }
                }
                .shadow(color: .black.opacity(textShadow ? 0.25 : 0), radius: 1, y: 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onDrop(of: barDropTypes, delegate: BarDropDelegate(target: nil, zone: nil, barWidth: geo.size.width,
                                                                 itemWidth: 0, intoFolder: false, targeted: .constant(false)))
            .contextMenu {
                AddMenu(zone: .right)
                Menu("Preset") {
                    ForEach(BarPreset.allCases) { p in Button(p.title) { BarStore.shared.apply(p) } }
                }
                Divider()
                Button("Bar Settings…") { BarActions.openSettings() }
            }
        }
        .font(.system(size: 13, weight: isMacLook ? .regular : .medium))
        .modifier(SchemeModifier(scheme: scheme))
        .clipShape(RoundedRectangle(cornerRadius: style == "floating" && position != "replace" ? 10 : 0, style: .continuous))
    }

    private func zone(_ z: Zone) -> some View {
        HStack(spacing: 2) {
            ForEach(store.layout[z]) { item in BarItemView(item: item, zone: z) }
        }
    }

    @ViewBuilder private var backgroundView: some View {
        switch background {
        case "dark": Color.black.opacity(opacity)
        case "light": Color.white.opacity(opacity)
        case "color": Color(hex: colorHex).opacity(opacity)
        case "macos":
            // Looks exactly like the transparent macOS menu bar: the strip of wallpaper behind it.
            if let strip = wallpaper.strip {
                Image(nsImage: strip).resizable()
            } else {
                VisualEffect()
            }
        default: VisualEffect().opacity(opacity)
        }
    }

    private var isMacLook: Bool { background == "macos" }
    private var textShadow: Bool { isMacLook && wallpaper.strip != nil && !wallpaper.isLight }

    private var scheme: ColorScheme? {
        switch background {
        case "macos": wallpaper.strip == nil ? nil : (wallpaper.isLight ? .light : .dark)
        case "dark": .dark
        case "light": .light
        case "color": Color(hex: colorHex).isLight ? .light : .dark
        default: nil
        }
    }
}

struct SchemeModifier: ViewModifier {
    let scheme: ColorScheme?
    func body(content: Content) -> some View {
        if let scheme { content.environment(\.colorScheme, scheme) } else { content }
    }
}

// MARK: - Bar item

struct BarItemView: View {
    let item: BarItem
    let zone: Zone
    @ObservedObject private var ui = BarUI.shared
    @ObservedObject private var stats = SystemStats.shared
    @AppStorage("barMagnify") private var magnify = true
    @AppStorage("barIconSize") private var iconSize = 18.0
    @AppStorage("barFolderNames") private var folderNames = true
    @AppStorage("barPosition") private var position = "top"
    @State private var hovering = false
    @State private var targeted = false
    @State private var bounce = false
    @State private var frame: CGRect = .zero
    private var width: CGFloat { frame.width }

    /// App-menu titles draw their own highlights; don't wrap them in the item hover effect.
    private var isPlain: Bool {
        switch item.kind {
        case .widget(.appMenus, _), .widget(.menuExtras, _): true
        default: false
        }
    }

    var body: some View {
        content
            .padding(.horizontal, isPlain ? 0 : 6)
            .padding(.vertical, 3)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(!isPlain && (hovering || isOpen) ? 0.13 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .scaleEffect(magnify && hovering && !isPlain && !isMenuWidget ? 1.12 : 1)
            .offset(y: bounce ? (position == "bottom" ? -5 : 4) : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hovering)
            .contentShape(Rectangle())
            .background(HoverTracker { hovering = $0 })
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
            .onTapGesture(perform: tap)
            .onDrag { NSItemProvider(object: "baritem:\(item.id.uuidString)" as NSString) }
            .onDrop(of: barDropTypes, delegate: BarDropDelegate(target: item.id, zone: zone, barWidth: 0, itemWidth: width,
                                                                 intoFolder: isFolder, targeted: $targeted))
            .contextMenu { menu }
            .help(item.displayName)
            .popover(isPresented: popoverBinding, arrowEdge: position == "bottom" ? .top : .bottom) { popoverContent }
    }

    private var isFolder: Bool { if case .folder = item.kind { true } else { false } }
    private var isMenuWidget: Bool { if case .widget(.appleMenu, _) = item.kind { true } else { false } }
    private var isOpen: Bool { ui.openPopover == item.id }

    private var popoverBinding: Binding<Bool> {
        Binding(get: { ui.openPopover == item.id },
                set: { if !$0 && ui.openPopover == item.id { ui.openPopover = nil } })
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .app(let path), .file(let path):
            let running = IconCache.bundleID(path).map { stats.runningBundleIDs.contains($0) } ?? false
            Image(nsImage: IconCache.icon(path))
                .resizable().interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .overlay(alignment: .bottom) {
                    if running {
                        Circle().fill(Color.primary.opacity(0.75)).frame(width: 3, height: 3).offset(y: 4)
                    }
                }
        case .folder(let name, let symbol, _):
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: iconSize * 0.78, weight: .semibold))
                if folderNames { Text(name) }
            }
        case .widget(let type, let symbol):
            WidgetView(type: type, symbol: symbol ?? "AAPL")
        case .spacer:
            Color.clear.frame(width: 14, height: 14)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 8)).opacity(hovering ? 0.4 : 0))
        case .divider:
            Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 1, height: 14)
        }
    }

    @ViewBuilder private var popoverContent: some View {
        switch item.kind {
        case .folder: TrayView(folderID: item.id)
        case .widget(.stock, let s): StockDetailView(symbol: s ?? "AAPL", itemID: item.id)
        case .widget(.clock, _), .widget(.date, _): CalendarPopover()
        case .widget(.menuSearch, _): MenuSearchView()
        default: EmptyView()
        }
    }

    private func tap() {
        switch item.kind {
        case .app(let path), .file(let path):
            launch(path)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.35)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { bounce = false }
            }
        case .widget(.menuSearch, _):
            if isOpen { ui.openPopover = nil; return }
            AppMenus.shared.snapshotForSearch()   // read the active app's menus before Topline takes focus
            NSApp.activate()
            ui.openPopover = item.id
        case .widget(.keepAwake, _):
            KeepAwake.shared.toggle()
        case .folder, .widget(.stock, _), .widget(.clock, _), .widget(.date, _):
            if isOpen { ui.openPopover = nil } else { NSApp.activate(); ui.openPopover = item.id }
        case .widget(.appleMenu, _):
            let point = screenPointBelow(frame)
            DispatchQueue.main.async { AppMenus.shared.popUp(index: 0, at: point) }
        case .widget(.peek, _):
            BarActions.peek()
        default: break
        }
    }

    @ViewBuilder private var menu: some View {
        switch item.kind {
        case .app(let p), .file(let p):
            Button("Open") { launch(p) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case .folder(let name, _, _):
            Button("Rename “\(name)”…") { BarStore.shared.renameFolder(item.id) }
            Menu("Folder Icon") {
                ForEach(folderSymbolChoices, id: \.self) { s in
                    Button { BarStore.shared.setFolderSymbol(item.id, s) } label: { Label(s, systemImage: s) }
                }
            }
        case .widget(.stock, let s):
            Button("Change Symbol (\(s ?? ""))…") { BarStore.shared.changeStockSymbol(item.id) }
            Button("Refresh Prices") { QuoteStore.shared.sync(force: true) }
        case .widget(.menuExtras, _):
            MenuExtrasMenu()
        case .widget(.keepAwake, _):
            ForEach([15, 30, 60, 120, 240], id: \.self) { m in
                Button(m < 60 ? "Keep Awake for \(m) Minutes" : "Keep Awake for \(m / 60) Hour\(m == 60 ? "" : "s")") {
                    KeepAwake.shared.start(minutes: m)
                }
            }
            Button("Keep Awake Indefinitely") { KeepAwake.shared.start(minutes: nil) }
            Button("Turn Off") { KeepAwake.shared.stop() }
        default:
            EmptyView()
        }
        Menu("Move to") {
            ForEach(Zone.allCases) { z in
                Button(z.title) { BarStore.shared.moveToZone(item.id, z) }.disabled(z == zone)
            }
        }
        Divider()
        AddMenu(zone: zone)
        Divider()
        Button("Remove from Bar") { BarStore.shared.remove(item.id) }
        Button("Bar Settings…") { BarActions.openSettings() }
    }
}

@MainActor
func launch(_ path: String) {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "app" {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    } else {
        NSWorkspace.shared.open(url)
    }
}

struct AddMenu: View {
    let zone: Zone
    var body: some View {
        Menu("Add to Bar (\(zone.title))") {
            Button("App…") { BarStore.shared.chooseApps(zone: zone) }
            Button("New Folder / Tray…") { BarStore.shared.addFolder(zone: zone) }
            Divider()
            ForEach(WidgetType.allCases) { t in
                Button { BarStore.shared.addWidget(t, zone: zone) } label: { Label(t.title, systemImage: t.symbol) }
            }
            Divider()
            Button("Spacer") { BarStore.shared.add(BarItem(kind: .spacer), zone: zone) }
            Button("Divider") { BarStore.shared.add(BarItem(kind: .divider), zone: zone) }
        }
    }
}

// MARK: - Drop handling

struct BarDropDelegate: DropDelegate {
    let target: UUID?
    let zone: Zone?          // nil = whole bar background (zone picked from drop x)
    let barWidth: CGFloat
    let itemWidth: CGFloat
    let intoFolder: Bool
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: barDropTypes) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let z: Zone = zone ?? {
            let x = info.location.x
            if x < barWidth / 3 { return .left }
            if x > barWidth * 2 / 3 { return .right }
            return BarUI.shared.notchWidth > 0 ? .left : .center
        }()
        let after = itemWidth > 0 && info.location.x > itemWidth / 2
        BarStore.shared.accept(info.itemProviders(for: barDropTypes), zone: z,
                               target: intoFolder ? nil : target, after: after,
                               folder: intoFolder ? target : nil)
        return true
    }
}

// MARK: - Folder tray

struct TrayView: View {
    let folderID: UUID
    @ObservedObject private var store = BarStore.shared
    @State private var targeted = false

    var body: some View {
        let folder = store.layout.find(folderID)
        if case .folder(let name, let symbol, let items)? = folder?.kind {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(.tint)
                    Text(name).font(.headline)
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Button { addApps() } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.tint).help("Add apps to \(name)")
                }
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("Drag apps here from Finder or from the bar")
                            .font(.callout).multilineTextAlignment(.center)
                        Button("Add Apps…") { addApps() }.controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(.tertiary))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 10) {
                        ForEach(items) { TrayCell(item: $0) }
                        AddAppCell { addApps() }
                    }
                }
            }
            .padding(14)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: targeted ? 2 : 0))
            .onDrop(of: barDropTypes, delegate: BarDropDelegate(target: folderID, zone: .left, barWidth: 0, itemWidth: 0,
                                                                 intoFolder: true, targeted: $targeted))
        }
    }

    /// Close the tray, then show the app picker (a modal panel can't sit on top of the tray popover).
    private func addApps() {
        let id = folderID
        BarUI.shared.openPopover = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { BarStore.shared.chooseApps(intoFolder: id) } }
    }
}

/// Dashed "+" tile at the end of a tray's grid.
struct AddAppCell: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])).foregroundStyle(.tertiary))
            Text("Add App").font(.caption)
        }
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: 76)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .background(HoverTracker { hovering = $0 })
        .onTapGesture(perform: action)
        .help("Add apps to this folder")
    }
}

struct TrayCell: View {
    let item: BarItem
    @State private var hovering = false
    @State private var targeted = false
    @State private var width: CGFloat = 0
    @AppStorage("barMagnify") private var magnify = true

    var body: some View {
        if case .app(let path) = item.kind { cell(path) } else if case .file(let path) = item.kind { cell(path) }
    }

    private func cell(_ path: String) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(path)).resizable().interpolation(.high).frame(width: 44, height: 44)
                .scaleEffect(magnify && hovering ? 1.15 : 1)
            Text(item.displayName).font(.caption).lineLimit(1).truncationMode(.tail)
        }
        .frame(width: 76)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: targeted ? 2 : 0))
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hovering)
        .contentShape(Rectangle())
        .background(HoverTracker { hovering = $0 })
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width } })
        .onTapGesture {
            launch(path)
            BarUI.shared.openPopover = nil
        }
        .onDrag { NSItemProvider(object: "baritem:\(item.id.uuidString)" as NSString) }
        .onDrop(of: barDropTypes, delegate: BarDropDelegate(target: item.id, zone: .left, barWidth: 0, itemWidth: width,
                                                             intoFolder: false, targeted: $targeted))
        .contextMenu {
            Button("Open") { launch(path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Divider()
            Menu("Move to Bar") {
                ForEach(Zone.allCases) { z in Button(z.title) { BarStore.shared.moveToZone(item.id, z) } }
            }
            Button("Remove from Folder") { BarStore.shared.remove(item.id) }
        }
        .help(item.displayName)
    }
}

// MARK: - Widgets

struct WidgetView: View {
    let type: WidgetType
    let symbol: String
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        Group {
            switch type {
            case .appleMenu:
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
            case .appMenus:
                AppMenusView()
            case .peek:
                Image(systemName: "menubar.arrow.up.rectangle").help("Show the macOS menu bar for 6 seconds")
            case .frontApp:
                Text(stats.frontApp).fontWeight(.bold)
            case .clock:
                TimelineView(.everyMinute) { ctx in Text(ctx.date, format: .dateTime.hour().minute()) }
            case .date:
                TimelineView(.everyMinute) { ctx in
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                }
            case .battery:
                HStack(spacing: 4) {
                    if let b = stats.battery {
                        Text("\(b)%")
                        Image(systemName: batterySymbol(b))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(b <= 20 && !stats.pluggedIn ? Color.red : Color.primary)
                    } else {
                        Image(systemName: "powerplug.fill")
                    }
                }
            case .cpu:
                HStack(spacing: 3) { Image(systemName: "cpu"); Text("\(Int(stats.cpu.rounded()))%") }
            case .memory:
                HStack(spacing: 3) { Image(systemName: "memorychip"); Text("\(Int(stats.memory.rounded()))%") }
            case .stock:
                StockWidget(symbol: symbol)
            case .menuExtras:
                MenuExtrasView()
            case .network:
                VStack(alignment: .trailing, spacing: -2) {
                    Text("↑ " + formatRate(stats.netUp))
                    Text("↓ " + formatRate(stats.netDown))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .frame(minWidth: 62, alignment: .trailing)
            case .menuSearch:
                Image(systemName: "magnifyingglass").help("Search the active app's menus")
            case .keepAwake:
                KeepAwakeWidget()
            }
        }
        .monospacedDigit()
    }

    private func batterySymbol(_ b: Int) -> String {
        if stats.charging || stats.pluggedIn { return "battery.100.bolt" }
        switch b {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}

/// "Finder  File  Edit  View  Go  Window  Help" — the front app's real menus, read via Accessibility.
struct AppMenusView: View {
    @ObservedObject private var menus = AppMenus.shared
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        if menus.trusted, menus.titles.count > 1 {
            HStack(spacing: 0) {
                ForEach(Array(menus.titles.enumerated()).dropFirst(), id: \.offset) { i, title in
                    MenuTitle(title: title, index: i)
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(stats.frontApp).fontWeight(.bold).padding(.horizontal, 8)
                if !menus.trusted {
                    Text("Show menus…")
                        .foregroundStyle(.secondary)
                        .onTapGesture { AppMenus.shared.resetPermission() }
                        .help("Allow Accessibility access so Topline can show File, Edit, View… for the active app")
                }
            }
        }
    }
}

struct MenuTitle: View {
    let title: String
    let index: Int
    @State private var hovering = false
    @State private var open = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Text(title)
            .fontWeight(index == 1 ? .bold : .regular)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(Color.primary.opacity(open ? 0.22 : hovering ? 0.1 : 0)).padding(.vertical, 1))
            .contentShape(Rectangle())
            .background(HoverTracker { hovering = $0 })
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
            .onTapGesture {
                open = true
                let point = screenPointBelow(frame)
                DispatchQueue.main.async {
                    AppMenus.shared.popUp(index: index, at: point)   // blocks until the menu closes
                    open = false
                }
            }
    }
}

struct StockWidget: View {
    let symbol: String
    @ObservedObject private var quotes = QuoteStore.shared
    @AppStorage("colorize") private var colorize = true
    @AppStorage("flashOnChange") private var flashOnChange = true
    @AppStorage("stockSparkline") private var sparkline = true
    @AppStorage("showPercent") private var showPercent = true
    @State private var flash: Color?

    var body: some View {
        Group {
            if let q = quotes.quotes[symbol] {
                let up = q.change >= 0
                let color: Color = up ? .green : .red
                HStack(spacing: 4) {
                    Text(shortSymbol).fontWeight(.semibold)
                    if sparkline, q.points.count > 2 {
                        Sparkline(points: q.points, color: colorize ? color : .primary).frame(width: 26, height: 11)
                    }
                    Text(formatPrice(q.price, q.currency))
                    if showPercent {
                        Text(String(format: "%@%@%.2f%%", up ? "▲" : "▼", up ? "+" : "", q.changePct))
                            .foregroundStyle(colorize ? color : .primary)
                    }
                }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(flash?.opacity(0.35) ?? .clear))
                .onChange(of: q.price) { old, new in
                    guard flashOnChange, old != new else { return }
                    withAnimation(.easeOut(duration: 0.15)) { flash = new > old ? .green : .red }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.easeIn(duration: 0.4)) { flash = nil }
                    }
                }
            } else {
                Text("\(shortSymbol) …")
            }
        }
        .onAppear { QuoteStore.shared.sync() }
    }

    /// "BTC-USD" → "BTC", "^GSPC" → "GSPC", keeps exchange suffixes like "SAP.DE".
    private var shortSymbol: String {
        var s = symbol
        if s.hasPrefix("^") { s.removeFirst() }
        if s.hasSuffix("-USD") { s = String(s.dropLast(4)) }
        return s
    }
}

struct StockDetailView: View {
    let symbol: String
    let itemID: UUID
    @ObservedObject private var quotes = QuoteStore.shared
    @ObservedObject private var alerts = PriceAlerts.shared
    @State private var above = ""
    @State private var below = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = quotes.quotes[symbol] {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.name).font(.headline).lineLimit(1)
                        Text(q.exchange.isEmpty ? q.symbol : "\(q.exchange): \(q.symbol)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    marketBadge(q)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatPrice(q.price, q.currency)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    Text("\(q.change >= 0 ? "+" : "-")\(formatPrice(abs(q.change), q.currency)) (\(String(format: "%+.2f%%", q.changePct)))")
                        .foregroundStyle(q.change >= 0 ? .green : .red).monospacedDigit()
                }
                PriceChart(symbol: symbol, currency: q.currency, previousClose: q.previousClose)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Prev close").foregroundStyle(.secondary); Text(formatPrice(q.previousClose, q.currency)) }
                    if let lo = q.dayLow, let hi = q.dayHigh {
                        GridRow { Text("Day range").foregroundStyle(.secondary); Text("\(formatPrice(lo, q.currency)) – \(formatPrice(hi, q.currency))") }
                    }
                    if let v = q.volume, v > 0 {
                        GridRow { Text("Volume").foregroundStyle(.secondary); Text(v.formatted(.number.notation(.compactName))) }
                    }
                    GridRow { Text("Last trade").foregroundStyle(.secondary); Text(q.time, style: .time) }
                }
                .font(.callout).monospacedDigit()
                Divider()
                alertSection(q)
                Divider()
                HStack {
                    Button("Yahoo Finance") {
                        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(symbol)")!)
                    }
                    Spacer()
                    Button("Change…") { BarUI.shared.openPopover = nil; BarStore.shared.changeStockSymbol(itemID) }
                }
                .controlSize(.small)
            } else {
                Text("Loading \(symbol)…")
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            let a = alerts.alerts[symbol]
            above = a?.above.map { String($0) } ?? ""
            below = a?.below.map { String($0) } ?? ""
        }
    }

    @ViewBuilder private func marketBadge(_ q: Quote) -> some View {
        let (text, color): (String, Color) = q.isExtendedHours ? ("Extended hours", .orange)
            : q.marketOpen == true ? ("Market open", .green) : q.marketOpen == false ? ("Market closed", .secondary) : ("", .clear)
        if !text.isEmpty {
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }

    @ViewBuilder private func alertSection(_ q: Quote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Price alert", systemImage: "bell").font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                TextField("Above", text: $above).frame(width: 80)
                TextField("Below", text: $below).frame(width: 80)
                Button("Set") {
                    alerts.set(symbol, above: Double(above.filter { "0123456789.".contains($0) }),
                               below: Double(below.filter { "0123456789.".contains($0) }))
                }
                if alerts.alerts[symbol] != nil {
                    Button("Clear") { above = ""; below = ""; alerts.set(symbol, above: nil, below: nil) }
                }
            }
            .textFieldStyle(.roundedBorder).controlSize(.small)
            if let a = alerts.alerts[symbol] {
                Text("Notifies when " + [a.above.map { "≥ \(formatPrice($0, q.currency))" }, a.below.map { "≤ \(formatPrice($0, q.currency))" }]
                    .compactMap { $0 }.joined(separator: " or "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Click the clock or date: month calendar + quick links.
struct CalendarPopover: View {
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.everyMinute) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day().year()).font(.headline)
                    Text("Week \(Calendar.current.component(.weekOfYear, from: ctx.date)) · day \(Calendar.current.ordinality(of: .day, in: .year, for: ctx.date) ?? 0) of the year")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Today") { date = Date() }
                Spacer()
                Button("Open Calendar") { launch("/System/Applications/Calendar.app"); BarUI.shared.openPopover = nil }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// The real macOS menu bar icons (Wi-Fi, Control Center, other apps) — click to open their menus.
struct MenuExtrasView: View {
    @ObservedObject private var extras = MenuExtras.shared
    @ObservedObject private var menus = AppMenus.shared
    @AppStorage("barIconSize") private var iconSize = 18.0
    @AppStorage("extrasMax") private var maxShown = 10.0
    @State private var showOverflow = false

    var body: some View {
        if menus.trusted {
            let all = extras.visible
            let limit = max(1, Int(maxShown))
            let shown = Array(all.suffix(limit))          // rightmost = system items (Control Center, Wi-Fi…)
            let overflow = Array(all.dropLast(limit))
            HStack(spacing: 0) {
                if !overflow.isEmpty {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { NSApp.activate(); showOverflow.toggle() }
                        .help("\(overflow.count) more menu bar icon\(overflow.count == 1 ? "" : "s")")
                        .popover(isPresented: $showOverflow, arrowEdge: .bottom) {
                            ExtrasOverflowView(items: overflow) { showOverflow = false }
                        }
                }
                ForEach(shown) { MenuExtraButton(extra: $0, size: iconSize) }
            }
        } else {
            Image(systemName: "switch.2")
                .padding(.horizontal, 6)
                .onTapGesture { AppMenus.shared.requestPermission() }
                .help("Allow Accessibility access to show your menu bar icons (Wi-Fi, Control Center…) here")
        }
    }
}

struct MenuExtraButton: View {
    let extra: MenuExtra
    let size: Double
    @State private var hovering = false

    var body: some View {
        MenuExtraIcon(extra: extra, size: size, real: true)
        .frame(minWidth: size + 6)
        .padding(.horizontal, 3)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.13 : 0)))
        .contentShape(Rectangle())
        .background(HoverTracker { hovering = $0 })
        .onTapGesture { MenuExtras.shared.press(extra) }
        .help(extra.name)
        .contextMenu {
            Button("Hide “\(extra.name)”") { MenuExtras.shared.hidden.insert(extra.id) }
            MenuExtrasMenu()
        }
    }
}

/// Show/hide individual menu bar icons.
struct MenuExtrasMenu: View {
    @ObservedObject private var extras = MenuExtras.shared
    var body: some View {
        Menu("Menu Bar Icons") {
            ForEach(extras.items) { e in
                Toggle(e.name.isEmpty ? e.bundleID : e.name, isOn: Binding(
                    get: { !extras.hidden.contains(e.id) },
                    set: { on in if on { extras.hidden.remove(e.id) } else { extras.hidden.insert(e.id) } }))
            }
            Divider()
            Button("Refresh") { MenuExtras.shared.refresh() }
        }
    }
}

// MARK: - AppKit bridges

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Hover detection that works even when this app isn't active (SwiftUI's onHover may not).
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { let v = TrackingView(); v.onChange = onChange; return v }
    func updateNSView(_ v: TrackingView, context: Context) { v.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x1C1C28
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    var isLight: Bool {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

/// Menu bar icons that didn't fit (the ones macOS would hide behind the notch).
struct ExtrasOverflowView: View {
    let items: [MenuExtra]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More menu bar icons").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(items) { e in
                    VStack(spacing: 4) {
                        MenuExtraIcon(extra: e, size: 26)
                        Text(e.name).font(.caption).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(width: 84, height: 58)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                    .onTapGesture { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MenuExtras.shared.press(e) } }
                    .help(e.name)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct MenuExtraIcon: View {
    let extra: MenuExtra
    let size: Double
    var real = false
    @ObservedObject private var extras = MenuExtras.shared
    var body: some View {
        if real, let img = extras.images[extra.id] {
            Image(nsImage: img)
        } else if let s = extra.symbol {
            Image(systemName: s).font(.system(size: size * 0.78, weight: .medium))
        } else if let icon = NSRunningApplication(processIdentifier: extra.pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}

struct KeepAwakeWidget: View {
    @ObservedObject private var awake = KeepAwake.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(awake.active ? Color.orange : Color.primary)
            if let until = awake.until {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let m = max(0, Int(until.timeIntervalSince(ctx.date) / 60) + 1)
                    Text(m >= 60 ? "\(m / 60)h\(m % 60 > 0 ? " \(m % 60)m" : "")" : "\(m)m").font(.system(size: 11).monospacedDigit())
                }
            }
        }
        .help(awake.active ? "Keeping your Mac awake — click to turn off (right-click for timers)"
                           : "Click to keep your Mac awake (right-click for timers)")
    }
}

/// Type to find and run any menu command of the app you're using.
struct MenuSearchView: View {
    var onDone: () -> Void = { BarUI.shared.openPopover = nil }
    @ObservedObject private var menus = AppMenus.shared
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [MenuHit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = menus.searchItems.filter { h in
            let hay = h.path.joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let q = query.lowercased()
        return Array(hits.sorted { a, b in
            let ap = a.title.lowercased().hasPrefix(q), bp = b.title.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            if a.enabled != b.enabled { return a.enabled }
            return a.title.count < b.title.count
        }.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(menus.searchAppName.isEmpty ? "app" : menus.searchAppName) menus…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            if !menus.trusted {
                Text("Allow Accessibility access to search menus.").foregroundStyle(.secondary)
                Button("Allow…") { AppMenus.shared.requestPermission() }
            } else if menus.searchLoading {
                Text("Reading \(menus.searchAppName) menus…").foregroundStyle(.secondary)
            } else if query.isEmpty {
                Text("\(menus.searchItems.count) commands in \(menus.searchAppName). Try “new window”, “export”, “zoom”…")
                    .font(.callout).foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("No matching commands").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, hit in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).fontWeight(.medium)
                                if !hit.trail.isEmpty { Text(hit.trail).font(.caption).foregroundStyle(i == selected ? .white.opacity(0.8) : .secondary) }
                            }
                            Spacer()
                            Text(hit.shortcut).font(.callout.monospaced()).foregroundStyle(i == selected ? .white.opacity(0.8) : .secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(i == selected ? Color.white : (hit.enabled ? Color.primary : Color.secondary))
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == selected ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { selected = i; runSelected() }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        .onAppear { focused = true }
        .onExitCommand { onDone() }
    }

    private func runSelected() {
        let r = results
        guard selected < r.count, r[selected].enabled else { return }
        let hit = r[selected]
        onDone()
        menus.run(hit)
    }
}

// MARK: - Smart overflow: never truncate — lowest-priority items move into a » tray

private struct ItemWidths: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension BarItem {
    /// Higher = stays on the bar longer when space runs out.
    var priority: Int {
        switch kind {
        case .widget(let t, _):
            switch t {
            case .clock: 100
            case .date: 90
            case .stock: 85
            case .menuExtras: 80
            case .appleMenu, .appMenus: 100
            case .battery: 60
            case .menuSearch: 50
            case .keepAwake: 45
            case .cpu: 40
            case .memory: 35
            case .network: 30
            case .frontApp: 25
            case .peek: 20
            }
        case .folder: 75
        case .app, .file: 70
        case .divider: 10
        case .spacer: 5
        }
    }
}

struct FitZone: View {
    let zone: Zone
    let available: CGFloat
    @ObservedObject private var store = BarStore.shared
    @State private var widths: [UUID: CGFloat] = [:]
    @State private var showMore = false
    private let spacing: CGFloat = 2
    private let moreWidth: CGFloat = 26

    var body: some View {
        let items = store.layout[zone]
        let hidden = hiddenIDs(items)
        HStack(spacing: spacing) {
            if !hidden.isEmpty {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: moreWidth - 4)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(showMore ? 0.15 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { NSApp.activate(); showMore.toggle() }
                    .help("\(hidden.count) more item\(hidden.count == 1 ? "" : "s") — not enough room next to the notch")
                    .popover(isPresented: $showMore, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("More").font(.headline).padding(.bottom, 2)
                            ForEach(items.filter { hidden.contains($0.id) }) { item in
                                BarItemView(item: item, zone: zone).fixedSize().frame(height: 28)
                            }
                            Text("Tip: right-click items to remove the ones you don't need.")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        }
                        .padding(12)
                    }
            }
            ForEach(items.filter { !hidden.contains($0.id) }) { item in
                BarItemView(item: item, zone: zone)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { g in Color.clear.preference(key: ItemWidths.self, value: [item.id: g.size.width]) })
            }
        }
        .onPreferenceChange(ItemWidths.self) { new in
            for (k, v) in new where abs((widths[k] ?? 0) - v) > 0.5 { widths[k] = v }
        }
    }

    /// Hides the lowest-priority items until the rest fit. Unmeasured items count as 30 pt;
    /// hidden items keep their last measured width.
    private func hiddenIDs(_ items: [BarItem]) -> Set<UUID> {
        func w(_ i: BarItem) -> CGFloat { widths[i.id] ?? 30 }
        var total = items.reduce(0) { $0 + w($1) } + spacing * CGFloat(max(0, items.count - 1))
        guard total > available else { return [] }
        var hidden = Set<UUID>()
        let budget = available - moreWidth - spacing
        let order = items.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.offset < b.offset
        }
        for (_, item) in order where total > budget {
            hidden.insert(item.id)
            total -= w(item) + spacing
        }
        return hidden
    }
}
