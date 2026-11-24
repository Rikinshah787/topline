import Foundation

/// All user settings, stored in UserDefaults. Keys match the @AppStorage keys in SettingsView.
enum Prefs {
    static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            // Stock
            "symbol": "AAPL",
            "stockSparkline": true,
            "extrasMax": 10.0,
            "refreshInterval": 15.0,
            "showSymbol": true,
            "showPercent": true,
            "colorize": true,
            "flashOnChange": true,
            // Folder
            "toggleIcon": "chevron",
            "dividerStyle": "line",
            "hoverExpand": false,
            "autoCollapse": 0.0,
            "alwaysHidden": false,
            "collapseOnLaunch": false,
            // Effects
            "animation": "slide",
            "animDuration": 0.25,
            "iconEffect": "fade",
            "sound": "none",
            "haptic": true,
            // Topline
            "barEnabled": true,
            "barPosition": "replace",
            "barStyle": "full",
            "barHeight": 28.0,
            "barBackground": "macos",
            "barColor": "#1C1C28",
            "barOpacity": 0.92,
            "barMagnify": true,
            "barIconSize": 18.0,
            "barFolderNames": true,
            "barPreset": "minimal",
            // macOS menu bar items
            "menuTicker": false,
            "menuFolder": false,
        ])
    }

    static var symbol: String {
        (d.string(forKey: "symbol") ?? "AAPL").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    static var refreshInterval: Double { max(5, d.double(forKey: "refreshInterval")) }
    static var showSymbol: Bool { d.bool(forKey: "showSymbol") }
    static var showPercent: Bool { d.bool(forKey: "showPercent") }
    static var colorize: Bool { d.bool(forKey: "colorize") }
    static var flashOnChange: Bool { d.bool(forKey: "flashOnChange") }

    static var toggleIcon: String { d.string(forKey: "toggleIcon") ?? "chevron" }
    static var dividerStyle: String { d.string(forKey: "dividerStyle") ?? "line" }
    static var hoverExpand: Bool { d.bool(forKey: "hoverExpand") }
    static var autoCollapse: Double { d.double(forKey: "autoCollapse") }
    static var alwaysHidden: Bool { d.bool(forKey: "alwaysHidden") }
    static var collapseOnLaunch: Bool { d.bool(forKey: "collapseOnLaunch") }

    static var animation: String { d.string(forKey: "animation") ?? "slide" }
    static var animDuration: Double { d.double(forKey: "animDuration") }
    static var iconEffect: String { d.string(forKey: "iconEffect") ?? "fade" }
    static var sound: String { d.string(forKey: "sound") ?? "none" }
    static var haptic: Bool { d.bool(forKey: "haptic") }

    static var barEnabled: Bool { d.bool(forKey: "barEnabled") }
    static var barPosition: String { d.string(forKey: "barPosition") ?? "replace" }
    static var barStyle: String { d.string(forKey: "barStyle") ?? "full" }
    static var barHeight: Double { min(44, max(20, d.double(forKey: "barHeight"))) }
    static var menuTicker: Bool { d.bool(forKey: "menuTicker") }
    static var menuFolder: Bool { d.bool(forKey: "menuFolder") }
}

/// Folder button icon choices: (id, display name, SF Symbol when collapsed, SF Symbol when open)
let folderIconSets: [(id: String, name: String, collapsed: String, expanded: String)] = [
    ("chevron",  "Chevron",  "chevron.left",            "chevron.right"),
    ("folder",   "Folder",   "folder.fill",             "folder"),
    ("dot",      "Dot",      "circle.fill",             "circle"),
    ("arrow",    "Arrow",    "arrow.left.circle.fill",  "arrow.right.circle"),
    ("eye",      "Eye",      "eye.slash",               "eye"),
    ("sparkles", "Sparkles", "sparkles",                "sparkle"),
    ("star",     "Star",     "star.fill",               "star"),
    ("tray",     "Tray",     "tray.full.fill",          "tray"),
]

/// Divider look: (id, display name, glyph)
let dividerStyles: [(id: String, name: String, glyph: String)] = [
    ("line",   "Line  │",    "│"),
    ("dashed", "Dashed  ┆",  "┆"),
    ("dot",    "Dot  •",     "•"),
    ("bar",    "Bar  ▍",     "▍"),
]

let feedbackSounds = ["none", "Pop", "Tink", "Bottle", "Morse", "Purr", "Glass", "Frog", "Submarine"]

extension Notification.Name {
    static let folderShowAll = Notification.Name("folderShowAll")
}
