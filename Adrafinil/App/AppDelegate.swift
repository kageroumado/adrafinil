import AppKit
import AdrafinilShared
import SwiftUI

/// Application delegate for the Adrafinil menu-bar app.
///
/// Drives the first-run setup window and the floating "While you were away" panel
/// (SPEC §7.3). Crucially, it performs **no** privileged action at launch — everything
/// that touches the system (helper/daemon registration, CLI symlink, hook installation)
/// is gated behind explicit user action in `InstallerView`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Manages the floating "While you were away" panel (SPEC §7.3).
    let summaryController = LidOpenSummaryController()
    private var installerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAwaySummary(_:)),
            name: .adrafinilAwaySummaryReceived,
            object: nil
        )

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

    // MARK: - Away summary

    @objc private func handleAwaySummary(_ notification: Notification) {
        guard let summary = notification.object as? AwaySummary else { return }
        let model = notification.userInfo?["model"] as? AppStatusModel
        summaryController.show(summary: summary) { [weak model] in
            model?.awaySummary = nil
        }
    }
}
