import AppKit
import QuartzCore

/// A collapsible "folder" in the menu bar.
///
/// Layout (right → left):   [ticker] [toggle] [divider │] ...folder icons... [always-hidden ┊] ...secret icons...
/// Collapsing sets the divider's length to 10 000 pt, which pushes every icon to its left off-screen.
/// Users ⌘-drag icons to the left of the divider to put them "in the folder".
@MainActor
final class FolderController: NSResponder {
    enum State { case collapsed, expanded, all }

    private let toggle: NSStatusItem
    private let divider: NSStatusItem
    private let deep: NSStatusItem          // "always hidden" divider
    private(set) var state: State = .expanded
    private var animTimer: Timer?
    private var collapseTimer: Timer?
    private let openSettings: () -> Void

    private let hiddenLength: CGFloat = 10_000
    private let dividerLength: CGFloat = 14
    private let slideDistance: CGFloat = 240
    private var lastAppearance = ""

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        let bar = NSStatusBar.system
        // Creation order matters on first launch: later items appear further left.
        toggle = bar.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "folder.toggle"
        divider = bar.statusItem(withLength: dividerLength)
        divider.autosaveName = "folder.divider"
        deep = bar.statusItem(withLength: dividerLength)
        deep.autosaveName = "folder.alwaysHidden"
        super.init()

        if let b = toggle.button {
            b.target = self
            b.action = #selector(toggleClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Click: open/close folder\n⌥-click: also show always-hidden icons\nRight-click: menu"
            b.addTrackingArea(NSTrackingArea(rect: .zero,
                                             options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self, userInfo: nil))
        }
        for item in [divider, deep] {
            item.button?.target = self
            item.button?.action = #selector(dividerClicked)
        }
        divider.button?.toolTip = "Folder divider — ⌘-drag icons to the LEFT of this line to put them in the folder"
        deep.button?.toolTip = "Always-hidden divider — icons LEFT of this only show with ⌥-click"

        deep.isVisible = Prefs.alwaysHidden
        if Prefs.alwaysHidden { deep.length = hiddenLength }
        applyAppearance(force: true)

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.prefsChanged() } }   // deferred: never re-enter layout
        }
        NotificationCenter.default.addObserver(forName: .folderShowAll, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setState(.all) }
        }

        if Prefs.collapseOnLaunch {
            // Wait for the menu bar to lay out so we can verify positions.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated { self?.setState(.collapsed, animated: false, feedback: false) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func teardown() {
        animTimer?.invalidate()
        collapseTimer?.invalidate()
        for item in [toggle, divider, deep] { NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - Interaction

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        if event?.modifierFlags.contains(.option) == true, Prefs.alwaysHidden {
            setState(state == .all ? .collapsed : .all)
            return
        }
        setState(state == .collapsed ? .expanded : .collapsed)
    }

    @objc private func dividerClicked() { setState(.collapsed) }

    override func mouseEntered(with event: NSEvent) {
        if Prefs.hoverExpand && state == .collapsed { setState(.expanded) }
    }

    private func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: state == .collapsed ? "Open Folder" : "Close Folder",
                  action: #selector(menuToggle), keyEquivalent: "").target = self
        if Prefs.alwaysHidden {
            m.addItem(withTitle: "Show Always-Hidden Icons", action: #selector(menuShowAll), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        let tip = NSMenuItem(title: "Tip: ⌘-drag icons left of │ to add them", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        m.addItem(tip)
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggle.menu = m
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    @objc private func menuToggle() { setState(state == .collapsed ? .expanded : .collapsed) }
    @objc private func menuShowAll() { setState(.all) }
    @objc private func menuSettings() { openSettings() }

    // MARK: - State

    func setState(_ new: State, animated: Bool = true, feedback: Bool = true) {
        if let problem = positionProblem(goingTo: new) {
            warn(problem)
            return
        }
        guard new != state || new == .collapsed && divider.length < hiddenLength else { return }
        state = new
        collapseTimer?.invalidate()

        let alwaysHidden = Prefs.alwaysHidden
        deep.isVisible = alwaysHidden
        switch new {
        case .collapsed:
            slide(to: hiddenLength, animated: animated) { [weak self] in
                guard let self, alwaysHidden, self.state == .collapsed else { return }
                self.deep.length = self.hiddenLength
            }
        case .expanded:
            if alwaysHidden { deep.length = hiddenLength }
            slide(to: dividerLength, animated: animated)
        case .all:
            if alwaysHidden { deep.length = dividerLength }
            slide(to: dividerLength, animated: animated)
        }

        updateToggleIcon(animated: animated)
        if feedback { playFeedback() }
        if new != .collapsed, Prefs.autoCollapse > 0 {
            collapseTimer = Timer.scheduledTimer(withTimeInterval: Prefs.autoCollapse, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setState(.collapsed) }
            }
        }
    }

    /// Prevents hiding the folder button itself if the dividers were dragged to the wrong side.
    private func positionProblem(goingTo new: State) -> String? {
        guard let t = toggle.button?.window?.frame else { return nil }
        if state != .collapsed, new == .collapsed,
           let d = divider.button?.window?.frame, d.midX > t.midX {
            return "The │ divider is to the right of the folder button. Hold ⌘ and drag the │ divider so it sits to the LEFT of the folder button, then try again."
        }
        if state == .all, new != .all, Prefs.alwaysHidden,
           let x = deep.button?.window?.frame, let d = divider.button?.window?.frame, x.midX > d.midX {
            return "The ┊ always-hidden divider must be to the LEFT of the │ folder divider. Hold ⌘ and drag it further left, then try again."
        }
        return nil
    }

    private func warn(_ text: String) {
        NSSound.beep()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Divider is in the wrong place"
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Effects

    private func slide(to target: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        animTimer?.invalidate()
        animTimer = nil
        let duration = Prefs.animDuration
        guard animated, Prefs.animation == "slide", duration > 0.01 else {
            divider.length = target
            completion?()
            return
        }

        let collapsing = target >= hiddenLength
        let from: CGFloat = collapsing ? min(divider.length, dividerLength) : dividerLength + slideDistance
        let to: CGFloat = collapsing ? dividerLength + slideDistance : target
        divider.length = from
        let start = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = collapsing ? p * p * p : 1 - pow(1 - p, 3)   // ease-in out, ease-out in
                self.divider.length = from + (to - from) * CGFloat(eased)
                if p >= 1 {
                    self.animTimer?.invalidate()
                    self.animTimer = nil
                    self.divider.length = target
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func updateToggleIcon(animated: Bool) {
        guard let b = toggle.button else { return }
        let set = folderIconSets.first { $0.id == Prefs.toggleIcon } ?? folderIconSets[0]
        let name = state == .collapsed ? set.collapsed : set.expanded
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Menu bar folder")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true

        let effect = Prefs.iconEffect
        guard animated, effect != "none" else { b.image = img; return }
        let pulses = effect == "pulse" ? 2 : 1
        fade(b, to: img, remaining: pulses)
    }

    private func fade(_ b: NSStatusBarButton, to img: NSImage?, remaining: Int) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            b.animator().alphaValue = 0.15
        }, completionHandler: {
            MainActor.assumeIsolated {
                b.image = img
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.16
                    b.animator().alphaValue = 1
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if remaining > 1 { self.fade(b, to: img, remaining: remaining - 1) }
                    }
                })
            }
        })
    }

    private func playFeedback() {
        let s = Prefs.sound
        if s != "none" { NSSound(named: NSSound.Name(s))?.play() }
        if Prefs.haptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: - Prefs

    private func prefsChanged() {
        applyAppearance(force: false)
        // Turning the always-hidden section on/off.
        if Prefs.alwaysHidden != deep.isVisible {
            deep.isVisible = Prefs.alwaysHidden
            if Prefs.alwaysHidden {
                deep.length = dividerLength
                state = .all                      // reveal it so the user can see/position it
                updateToggleIcon(animated: false)
            }
        }
    }

    private func applyAppearance(force: Bool) {
        let key = Prefs.toggleIcon + "|" + Prefs.dividerStyle
        guard force || key != lastAppearance else { return }
        lastAppearance = key

        let style = dividerStyles.first { $0.id == Prefs.dividerStyle } ?? dividerStyles[0]
        let font = NSFont.systemFont(ofSize: 14, weight: .light)
        divider.button?.attributedTitle = NSAttributedString(
            string: style.glyph, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font])
        deep.button?.attributedTitle = NSAttributedString(
            string: "┊", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font])
        updateToggleIcon(animated: false)
    }
}
