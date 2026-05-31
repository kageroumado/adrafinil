import AppKit
import AdrafinilShared
import SwiftUI
import UserNotifications

/// Application delegate for the Adrafinil menu-bar app.
///
/// Drives the first-run setup window and the "While you were away" recap notification.
/// Crucially, it performs **no** privileged action at launch — everything that touches the
/// system (helper/daemon registration, CLI symlink, agent setup) is gated behind explicit
/// user action in `InstallerView`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var installerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance. macOS blocks double-launch from Finder, but launching via Xcode (or a
        // different build path) bypasses that — and Xcode's Stop doesn't reliably kill a menu-bar
        // (LSUIElement) app, so old copies pile up. Terminate any other running instance on launch.
        terminateOtherInstances()

        // Be the notification delegate so the away recap shows as a banner even when Adrafinil
        // is the frontmost app (otherwise the system routes it silently to Notification Center).
        UNUserNotificationCenter.current().delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAwaySummary(_:)),
            name: .adrafinilAwaySummaryReceived,
            object: nil
        )

#if DEBUG
        // Daemon-free UI gallery: launch with `-ADRAFINIL_GALLERY 1` to review every surface/state.
        if UserDefaults.standard.bool(forKey: "ADRAFINIL_GALLERY") {
            presentGallery()
            return
        }
        // Every DEBUG run opens the interactive control panel and skips the real first-run flow,
        // so the UI can be exercised with mock scenarios. Flip "Use live daemon" in the panel to
        // talk to the real daemon instead.
        presentDebugControlPanel()
        return
#endif

        // First run: present the setup flow and nothing else. No privileged work happens
        // until the user proceeds — helper/daemon registration, the CLI symlink, and hook
        // installation are all triggered by explicit buttons inside InstallerView. On later
        // launches the daemon is already registered with launchd and starts on its own; the
        // app simply connects to it (a failed connection before setup is handled gracefully).
        if HelperInstaller.isFirstRun {
            presentInstaller()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Force-quit any other running copy of this app, leaving only this instance. Force (not
    /// graceful) so a wedged stray that's ignoring events still goes away.
    private func terminateOtherInstances() {
        let me = NSRunningApplication.current
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == me.bundleIdentifier && app.processIdentifier != me.processIdentifier {
            app.forceTerminate()
        }
    }

    /// Shows the first-run setup window. Hosted from AppKit because this is a menu-bar
    /// (`LSUIElement`) app, which does not auto-present SwiftUI windows at launch.
    func presentInstaller() {
        if let window = installerWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: InstallerView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Adrafinil Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        installerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

#if DEBUG
    private var galleryWindow: NSWindow?
    private var debugPanelWindow: NSWindow?
    private var debugInstallerWindow: NSWindow?

    /// Presents the interactive debug control panel (DEBUG only).
    func presentDebugControlPanel() {
        DebugControl.shared.appDelegate = self
        if let window = debugPanelWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hosting = NSHostingController(rootView: DebugControlPanel(control: .shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Adrafinil — Debug Controls"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        debugPanelWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the installer flow with mock providers — walking it touches nothing on disk.
    func presentInstallerPreview() {
        let hosting = NSHostingController(
            rootView: InstallerView(setup: PreviewSetupProvider(), agentHooks: PreviewAgentHooksProvider())
        )
        let window = debugInstallerWindow ?? NSWindow(contentViewController: hosting)
        window.contentViewController = hosting
        window.title = "Adrafinil Setup (mock)"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        debugInstallerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Presents the daemon-free UI gallery window (DEBUG only).
    func presentGallery() {
        if let window = galleryWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hosting = NSHostingController(rootView: GalleryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Adrafinil — UI Gallery"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1180, height: 860))
        window.center()
        window.isReleasedWhenClosed = false
        galleryWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
#endif

    // MARK: - Away summary

    @objc private func handleAwaySummary(_ notification: Notification) {
        guard let summary = notification.object as? AwaySummary else { return }
        AwayNotifier.shared.deliver(summary)
        (notification.userInfo?["model"] as? AppStatusModel)?.awaySummary = nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the recap as a banner even while Adrafinil is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
