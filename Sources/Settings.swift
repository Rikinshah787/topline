import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Topline Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            BarTab().tabItem { Label("Bar", systemImage: "menubar.rectangle") }
            FolderTab().tabItem { Label("Folder", systemImage: "folder") }
            EffectsTab().tabItem { Label("Effects", systemImage: "sparkles") }
            StockTab().tabItem { Label("Stocks", systemImage: "chart.line.uptrend.xyaxis") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(width: 560, height: 580)
    }
}

// MARK: - Bar

struct BarTab: View {
    @AppStorage("barEnabled") private var enabled = true
    @AppStorage("barPosition") private var position = "replace"
    @AppStorage("barStyle") private var style = "full"
    @AppStorage("barHeight") private var height = 28.0
    @AppStorage("barBackground") private var background = "macos"
    @AppStorage("barColor") private var colorHex = "#1C1C28"
    @AppStorage("barOpacity") private var opacity = 0.92
    @AppStorage("barIconSize") private var iconSize = 18.0
    @AppStorage("barMagnify") private var magnify = true
    @AppStorage("barFolderNames") private var folderNames = true
    @AppStorage("extrasMax") private var extrasMax = 10.0
    @AppStorage("realMenuIcons") private var realIcons = false
    @AppStorage("menuSearchHotkey") private var menuSearchHotkey = true
    @AppStorage("barPreset") private var preset = "minimal"
    @State private var confirmReset = false
    @ObservedObject private var ui = BarUI.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Topline", isOn: $enabled).font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Text("• **Drag apps, files or folders from Finder** onto the bar to add them.")
                    Text("• **Drag icons** on the bar to reorder. **Drop onto a folder** to put it in the tray.")
                    Text("• **Right-click** the bar to add widgets (stocks, menu bar icons, clock, CPU…), folders, spacers.")
                    Text("• Right-click any item to rename, change icon, move or remove it.")
                }
                .font(.callout)
            }
            Section {
                HStack(spacing: 10) {
                    ForEach(BarPreset.allCases) { p in
                        PresetCard(preset: p, selected: preset == p.rawValue) { BarStore.shared.apply(p) }
                    }
                }
            } header: {
                Text("Preset")
            } footer: {
                Text("Presets only change widgets. Your apps, folders and stocks stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Picker("Position", selection: $position) {
                    Text("Replace menu bar").tag("replace")
                    Text("Below menu bar").tag("top")
                    Text("Bottom").tag("bottom")
                }.pickerStyle(.segmented)
                if position == "replace" {
                    Text("Topline sits exactly where the macOS menu bar is and covers it. The **Menu Bar Icons** widget brings Wi-Fi, Control Center and your other apps' icons onto Topline.")
                        .font(.caption).foregroundStyle(.secondary)
                    if ui.menuBarAutoHides {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("macOS is auto-hiding its menu bar, so windows can slide under Topline. Set “Automatically hide and show the menu bar” to **In Full Screen Only** or **Never**.")
                                .font(.caption)
                            Button("Open…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
                            }
                        }
                    }
                } else {
                    Picker("Style", selection: $style) {
                        Text("Full width").tag("full"); Text("Floating").tag("floating")
                    }.pickerStyle(.segmented)
                    LabeledSlider(title: "Height", value: $height, range: 22...40, format: "%.0f pt")
                }
                LabeledSlider(title: "Icon size", value: $iconSize, range: 14...28, format: "%.0f pt")
            }
            Section("Look") {
                Picker("Background", selection: $background) {
                    Text("Same as macOS (transparent)").tag("macos")
                    Text("Glass (blur)").tag("blur"); Text("Dark").tag("dark")
                    Text("Light").tag("light"); Text("Custom color").tag("color")
                }
                if background == "color" {
                    ColorPicker("Color", selection: Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString }),
                                supportsOpacity: false)
                }
                if background != "macos" {
                    LabeledSlider(title: "Opacity", value: $opacity, range: 0.3...1, format: "%.0f%%", scale: 100)
                }
                Toggle("Magnify icons on hover", isOn: $magnify)
                Toggle("Show folder names", isOn: $folderNames)
            }
            Section("Apple menu, app menus & menu bar icons") {
                AccessibilityRow()
                Stepper("Show up to \(Int(extrasMax)) menu bar icons, the rest go in the « overflow tray",
                        value: $extrasMax, in: 1...30)
                Toggle(isOn: Binding(get: { realIcons }, set: { on in
                    realIcons = on
                    if on { MenuExtras.shared.requestScreenRecording() } else { MenuExtras.shared.captureIcons() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show real menu bar icon artwork")
                        Text("Needs Screen Recording permission — Topline only captures the menu bar, never stores or sends images. Off: system symbols and app icons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("⌃⌥Space opens Menu Search (any app, anywhere)", isOn: $menuSearchHotkey)
                    .onChange(of: menuSearchHotkey) { _, _ in GlobalHotkey.sync() }
            }
            Section {
                Button("Reset bar to default layout…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset Topline to the default layout? Your folders and items will be removed.",
                            isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { BarStore.shared.reset() }
        }
    }
}

struct PresetCard: View {
    let preset: BarPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // A tiny bar: one dot per widget, so the density is visible at a glance.
                HStack(spacing: 3) {
                    Capsule().frame(width: 14, height: 4)
                    Spacer(minLength: 4)
                    ForEach(0..<(preset.widgets.count + min(preset.maxStocks, 3)), id: \.self) { _ in
                        Circle().frame(width: 4, height: 4)
                    }
                }
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 7).frame(height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                Text(preset.title).font(.headline)
                Text(preset.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct AccessibilityRow: View {
    @ObservedObject private var menus = AppMenus.shared
    var body: some View {
        HStack {
            Image(systemName: menus.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(menus.trusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(menus.trusted ? "Menus & icons enabled" : "Allow access to show File, Edit, View… menus and menu bar icons")
                Text("Needs Accessibility permission: System Settings → Privacy & Security → Accessibility → Topline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !menus.trusted {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Grant Access…") { AppMenus.shared.requestPermission() }
                    Button("Fix Permission") { AppMenus.shared.resetPermission() }
                        .help("Already allowed but still asking? This clears the stale entry so macOS can ask again.")
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, value * scale)).monospacedDigit().frame(width: 54, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Folder

struct FolderTab: View {
    @AppStorage("toggleIcon") private var toggleIcon = "chevron"
    @AppStorage("dividerStyle") private var dividerStyle = "line"
    @AppStorage("hoverExpand") private var hoverExpand = false
    @AppStorage("autoCollapse") private var autoCollapse = 0.0
    @AppStorage("alwaysHidden") private var alwaysHidden = false
    @AppStorage("collapseOnLaunch") private var collapseOnLaunch = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("How to put icons in the folder", systemImage: "hand.draw").font(.headline)
                    Text("1. Open the folder so you can see the **│** divider next to the folder button.")
                    Text("2. Hold **⌘ Command** and drag any menu bar icon to the **left** of the │ divider.")
                    Text("3. Click the folder button to hide or show them. Right-click it for more options.")
                }
                .font(.callout)
            }

            Section("Look") {
                Picker("Folder button", selection: $toggleIcon) {
                    ForEach(folderIconSets, id: \.id) { s in
                        Label(s.name, systemImage: s.collapsed).tag(s.id)
                    }
                }
                Picker("Divider", selection: $dividerStyle) {
                    ForEach(dividerStyles, id: \.id) { s in Text(s.name).tag(s.id) }
                }
            }

            Section("Behavior") {
                Toggle("Open folder when hovering over the button", isOn: $hoverExpand)
                Picker("Auto-close folder", selection: $autoCollapse) {
                    Text("Never").tag(0.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 10 seconds").tag(10.0)
                    Text("After 30 seconds").tag(30.0)
                    Text("After 1 minute").tag(60.0)
                }
                Toggle("Start with folder closed", isOn: $collapseOnLaunch)
                Toggle("Always-hidden section (⌥-click button to reveal)", isOn: $alwaysHidden)
                if alwaysHidden {
                    Text("Icons dragged left of the **┊** divider stay hidden even when the folder is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Show everything now") {
                    NotificationCenter.default.post(name: .folderShowAll, object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Effects

struct EffectsTab: View {
    @AppStorage("animation") private var animation = "slide"
    @AppStorage("animDuration") private var animDuration = 0.25
    @AppStorage("iconEffect") private var iconEffect = "fade"
    @AppStorage("sound") private var sound = "none"
    @AppStorage("haptic") private var haptic = true
    @AppStorage("flashOnChange") private var flashOnChange = true

    var body: some View {
        Form {
            Section("Folder open / close") {
                Picker("Animation", selection: $animation) {
                    Text("Slide").tag("slide")
                    Text("Instant").tag("instant")
                }
                .pickerStyle(.segmented)
                if animation == "slide" {
                    HStack {
                        Text("Speed")
                        Slider(value: $animDuration, in: 0.1...0.8) {
                            EmptyView()
                        } minimumValueLabel: { Text("Fast").font(.caption) } maximumValueLabel: { Text("Slow").font(.caption) }
                    }
                }
                Picker("Button effect", selection: $iconEffect) {
                    Text("Fade").tag("fade")
                    Text("Pulse").tag("pulse")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
                Picker("Sound", selection: $sound) {
                    ForEach(feedbackSounds, id: \.self) { s in Text(s == "none" ? "None" : s).tag(s) }
                }
                .onChange(of: sound) { _, s in
                    if s != "none" { NSSound(named: NSSound.Name(s))?.play() }
                }
                Toggle("Trackpad haptic tap", isOn: $haptic)
            }
            Section("Stock ticker") {
                Toggle("Flash green/red when the price changes", isOn: $flashOnChange)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Stock

struct StockTab: View {
    @AppStorage("symbol") private var symbol = "AAPL"
    @AppStorage("refreshInterval") private var refreshInterval = 15.0
    @AppStorage("showSymbol") private var showSymbol = true
    @AppStorage("showPercent") private var showPercent = true
    @AppStorage("colorize") private var colorize = true
    @AppStorage("flashOnChange") private var flashOnChange = true
    @AppStorage("stockSparkline") private var sparkline = true
    @ObservedObject private var store = BarStore.shared
    @ObservedObject private var quotes = QuoteStore.shared
    @ObservedObject private var alerts = PriceAlerts.shared

    var body: some View {
        Form {
            Section {
                ForEach(store.stockSymbols, id: \.id) { row in
                    HStack {
                        Text(row.symbol).fontWeight(.semibold).frame(width: 90, alignment: .leading)
                        if let q = quotes.quotes[row.symbol] {
                            Text(q.name).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(formatPrice(q.price, q.currency)).monospacedDigit()
                            Text(String(format: "%+.2f%%", q.changePct)).monospacedDigit()
                                .foregroundStyle(q.change >= 0 ? .green : .red).frame(width: 64, alignment: .trailing)
                        } else {
                            Spacer()
                        }
                        if alerts.alerts[row.symbol] != nil {
                            Image(systemName: "bell.fill").foregroundStyle(.orange).help("Price alert set")
                        }
                        Button { BarStore.shared.remove(row.id) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.red).help("Remove from bar")
                    }
                }
                Button { BarStore.shared.addWidget(.stock, zone: .right) } label: { Label("Add Stock…", systemImage: "plus") }
            } header: {
                Text("Stocks on your bar")
            } footer: {
                Text("Search by company or ticker. Works with stocks, ETFs, indexes (^GSPC), crypto (BTC-USD), currencies (EURUSD=X) and international exchanges (SAP.DE, 7203.T). Click a stock on the bar for its chart and price alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Toggle("Mini chart on the bar", isOn: $sparkline)
                Toggle("Show % change", isOn: $showPercent)
                Toggle("Green / red colors", isOn: $colorize)
                Toggle("Flash when the price changes", isOn: $flashOnChange)
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                }
            }
            Section("Classic macOS menu bar ticker") {
                HStack {
                    Text("Symbol")
                    Spacer()
                    Text(symbol).fontWeight(.semibold)
                    Button("Change…") { StockPicker.pick(title: "Menu Bar Ticker") { symbol = $0.uppercased() } }
                }
                Toggle("Show symbol", isOn: $showSymbol)
                Text("Only used when “Stock price in the macOS menu bar” is on (General tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Market data from Yahoo Finance, may be delayed. Not investment advice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralTab: View {
    @AppStorage("menuTicker") private var menuTicker = true
    @AppStorage("menuFolder") private var menuFolder = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    var body: some View {
        Form {
            Section("Items in the macOS menu bar") {
                Toggle("Stock price in the macOS menu bar", isOn: $menuTicker)
                Toggle("Menu bar folder (‹ button that hides other menu bar icons)", isOn: $menuFolder)
                Text("Turn these off if you only want Topline. Re-open the app from Finder any time to get back to Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = ""
                        } catch {
                            loginError = "Couldn't change login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if !loginError.isEmpty {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("About") {
                HStack {
                    Text("Topline \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Button("Quit Topline", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Welcome (first launch)

@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView { [weak w] in w?.close() })
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @ObservedObject private var store = BarStore.shared
    @ObservedObject private var menus = AppMenus.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("Welcome to Topline").font(.system(size: 26, weight: .bold))
                Text("Your menu bar, rebuilt — live markets, your apps and trays, all on top.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                step(1, "chart.line.uptrend.xyaxis", "Pick your markets",
                     store.stockSymbols.isEmpty ? "Add any stock, ETF, index or crypto." :
                        "Watching " + store.stockSymbols.map(\.symbol).joined(separator: ", ") + ". Click one on the bar for charts & alerts.") {
                    Button("Add Stock…") { BarStore.shared.addWidget(.stock, zone: .right) }
                }
                step(2, "lock.shield", "Show menus & menu bar icons",
                     menus.trusted ? "Done — File, Edit, View… and Wi-Fi, Control Center are on Topline."
                                   : "Allow Accessibility so Topline can show the active app's menus and your menu bar icons.") {
                    if menus.trusted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    } else {
                        Button("Allow…") { AppMenus.shared.requestPermission() }
                    }
                }
                step(3, "hand.draw", "Make it yours",
                     "Drag apps from Finder onto the bar, drop them on a tray, right-click for widgets.") {
                    Button("Settings…") { BarActions.openSettings() }
                }
            }
            Spacer(minLength: 0)
            Button(action: done) { Text("Get Started").frame(maxWidth: .infinity) }
                .controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 24)
        .frame(width: 520, height: 560)
    }

    private func step<A: View>(_ n: Int, _ icon: String, _ title: String, _ detail: String,
                               @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}
