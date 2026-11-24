import AppKit
import SwiftUI

/// Borderless panel that never steals focus from the app you're using.
final class BarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Set level last (isFloatingPanel resets it). Just below the real menu bar, so if macOS's
        // menu bar slides down (auto-hide) it appears on top of Topline.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class BarController {
    private var panel: BarPanel?
    private var mouseMonitor: Any?
    private var watchdog: Timer?
    private var applying = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }   // deferred: never re-enter layout
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }   // deferred: never re-enter layout
        }
        // Close trays/popovers when clicking anywhere outside the app.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { BarUI.shared.openPopover = nil }
        }
        // Menu bar auto-hide / Dock changes don't always post a notification — re-check periodically.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }   // deferred: never re-enter layout
        }
        BarActions.peek = { [weak self] in self?.peek() }
        apply()
    }

    private var peeking = false

    /// Hides Topline for a few seconds so the real macOS menu bar underneath is reachable (Wi-Fi, Control Center…).
    func peek() {
        guard let panel, !peeking else { return }
        peeking = true
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                self?.peeking = false
                self?.apply()
            }
        }
    }

    private func apply() {
        guard !applying, !peeking else { return }
        applying = true
        defer { applying = false }
        syncSystemMenuBar()
        guard Prefs.barEnabled else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let p = BarPanel()
            let host = FirstMouseHostingView(rootView: BarRootView())
            host.sizingOptions = []
            p.contentView = host
            panel = p
        }
        guard let panel, let screen = NSScreen.screens.first, let frame = targetFrame(screen) else { return }
        let replace = Prefs.barPosition == "replace"
        // Replace mode sits above the real menu bar (covering it); otherwise just below it.
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + (replace ? 2 : -1))
        if panel.level != level { panel.level = level }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        BarUI.shared.panelFrame = frame
        panel.hasShadow = Prefs.barStyle == "floating" && !replace
        if UserDefaults.standard.string(forKey: "barBackground") ?? "macos" == "macos" {
            Wallpaper.shared.update(screen: screen, barHeight: frame.height)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Replace mode works best when macOS keeps its menu bar visible on the desktop (so windows stay below it).
    /// We never change the system setting ourselves — Settings shows a hint if the menu bar is auto-hiding.
    private func syncSystemMenuBar() {
        guard let screen = NSScreen.screens.first else { return }
        let hides = screen.frame.maxY - screen.visibleFrame.maxY <= 0
        if BarUI.shared.menuBarAutoHides != hides { BarUI.shared.menuBarAutoHides = hides }
    }

    /// Height of the real macOS menu bar (33 pt on notched MacBooks, 24 pt otherwise).
    private func nativeMenuBarHeight(_ screen: NSScreen) -> CGFloat {
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        if reserved > 0 { return reserved }
        return screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top + 1 : 24
    }

    private func targetFrame(_ screen: NSScreen) -> NSRect? {
        let f = screen.frame, vf = screen.visibleFrame
        let h = CGFloat(Prefs.barHeight)
        let floating = Prefs.barStyle == "floating"
        let m: CGFloat = floating ? 6 : 0
        let rect: NSRect
        switch Prefs.barPosition {
        case "replace":
            let mh = nativeMenuBarHeight(screen)
            rect = NSRect(x: f.minX, y: f.maxY - mh, width: f.width, height: mh)
        case "bottom":
            rect = NSRect(x: f.minX + m, y: vf.minY + m, width: f.width - 2 * m, height: h)
        default:
            // Directly under the macOS menu bar.
            rect = NSRect(x: f.minX + m, y: vf.maxY - h - m, width: f.width - 2 * m, height: h)
        }
        // Leave a gap for the camera notch if the bar overlaps it.
        var notch: CGFloat = 0
        if screen.safeAreaInsets.top > 0, rect.maxY > f.maxY - screen.safeAreaInsets.top,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = r.minX - l.maxX
        }
        if BarUI.shared.notchWidth != notch { BarUI.shared.notchWidth = notch }
        return rect
    }
}
