import AppKit

/// Shows Adrafinil in the Dock only while a real window is on screen.
///
/// Adrafinil is a menu-bar app (`LSUIElement`), so it launches as `.accessory` — menu-bar item, no
/// Dock icon. But its Settings and first-run Setup windows should behave like ordinary windows while
/// open (Dock icon, app menu, ⌘-Tab). This watches window visibility and promotes the app to
/// `.regular` whenever a standard window is showing, demoting back to `.accessory` once the last one
/// closes. The MenuBarExtra popover, the status item, and modal `NSPanel`s (alerts) don't count —
/// they aren't main-capable standard windows.
@MainActor
final class DockVisibilityController {
    private var observers: [NSObjectProtocol] = []

    func start() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `willClose` fires *before* the window leaves the list, so defer the recompute one
                // turn to read the settled state rather than special-casing the closing window.
                DispatchQueue.main.async { self?.update() }
            }
            observers.append(token)
        }
        update()
    }

    private func update() {
        let hasStandardWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !(window is NSPanel)
        }
        let desired: NSApplication.ActivationPolicy = hasStandardWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        // Promoting from .accessory can leave the just-opened window behind other apps; pull it
        // forward. (Demoting needs no activation.)
        if desired == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}
