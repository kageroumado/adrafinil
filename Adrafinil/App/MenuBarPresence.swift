import AdrafinilShared
import AppKit
import Observation

/// Keeps "Show in menu bar" from being a dead end (approach ported from WheelClick).
///
/// With the icon hidden the app has no visible surface at all, and the old escape hatch — opening
/// the Settings scene from AppKit — doesn't work: the `showSettingsWindow:` selector isn't in a
/// menu-bar-only app's responder chain, so the relaunch appeared to do nothing and the only way
/// back was System Settings → Menu Bar. Instead, relaunching the running app (Spotlight, Finder)
/// now briefly slots the icon back into the bar and opens its popover — Settings is one click away
/// from there — and the icon vanishes again when the popover closes. The first hide explains that
/// path once.
@MainActor
@Observable
final class MenuBarPresence {
    static let shared = MenuBarPresence()

    /// True between `openMenu` revealing a hidden icon and the popover closing: the icon is on the
    /// bar only to host the popover, and `popoverDidClose` sends it away again. OR-ed into
    /// `MenuBarExtra(isInserted:)` in `AdrafinilApp`, so it never touches the persisted setting.
    private(set) var temporarilyShown = false

    private static let revealInitialDelay = 0.15
    private static let revealPollInterval = 0.05
    private static let revealTimeout = 2.0

    /// Pops the popover as if the icon were clicked; if the icon is hidden, temporarily reveals it
    /// first so the popover lands in its normal place instead of a computed guess.
    func openMenu() {
        // Decide from the setting, not from window presence: MenuBarExtra can keep its status-bar
        // window alive while removed from the bar, so a found button doesn't mean a visible icon —
        // clicking that detached button opens the popover with no icon above it.
        if !AdrafinilSettings.load().showInMenuBar {
            temporarilyShown = true
        }
        // MenuBarExtra inserts the item asynchronously (and a fixed delay is a guess — a slow or
        // busy system can take noticeably longer), so poll until the button has a real on-screen
        // frame and, once the time budget is spent, click anyway so the menu always opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealInitialDelay) { [weak self] in
            self?.clickWhenButtonReady(remaining: Self.revealTimeout - Self.revealInitialDelay)
        }
    }

    /// The popover closed. The icon was only on the bar to host it — send it back to whatever the
    /// setting says (still hidden, unless the user just re-enabled "Show in menu bar" from within
    /// Settings, which persists independently).
    func popoverDidClose() {
        temporarilyShown = false
    }

    /// The user drove the icon's presence directly (⌘-drag off the bar); any in-flight temporary
    /// reveal is moot.
    func endTemporaryReveal() {
        temporarilyShown = false
    }

    // MARK: - First-hide notice

    private static let hiddenNoticeShownKey = "menuBarHiddenNoticeShown"

    /// A one-time heads-up the first time the icon disappears, so hiding it isn't a dead end: the
    /// popover is still one Spotlight search away.
    func announceHiddenIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hiddenNoticeShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hiddenNoticeShownKey)
        // Deferred so the toggle (or drag session) that triggered this finishes before the modal
        // takes over.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Adrafinil is hidden from the menu bar"
            alert.informativeText = """
            The icon is gone, but Adrafinil keeps working.

            To open its menu again, search “Adrafinil” in Spotlight (⌘Space) and press \
            Return — then turn “Show in menu bar” back on in Settings to bring the icon back.
            """
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Status item plumbing

    private func clickWhenButtonReady(remaining: Double) {
        guard let button = statusBarButton() else {
            // Not inserted yet (SwiftUI reacts to `temporarilyShown` on its own schedule); keep
            // waiting within the budget.
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealPollInterval) { [weak self] in
                    self?.clickWhenButtonReady(remaining: remaining - Self.revealPollInterval)
                }
            }
            return
        }
        let ready = button.window.map { $0.frame.width > 0 && $0.frame.origin != .zero } ?? false
        if ready || remaining <= 0 {
            // The window-style popover closes itself the moment it isn't key; clicked from a
            // fresh, not-yet-active launch it would flash open and vanish. Activate first.
            NSApp.activate(ignoringOtherApps: true)
            button.performClick(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealPollInterval) { [weak self] in
            self?.clickWhenButtonReady(remaining: remaining - Self.revealPollInterval)
        }
    }

    /// The status item's button, dug out of the app's windows — `MenuBarExtra` never exposes its
    /// `NSStatusItem`, but the item's button lives in a status-bar window of this process.
    private func statusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            guard window.className.contains("StatusBarWindow"), let content = window.contentView else { continue }
            if let button = content as? NSStatusBarButton { return button }
            if let button = firstStatusBarButton(in: content) { return button }
        }
        return nil
    }

    private func firstStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        for subview in view.subviews {
            if let button = subview as? NSStatusBarButton { return button }
            if let button = firstStatusBarButton(in: subview) { return button }
        }
        return nil
    }
}
