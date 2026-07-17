import AdrafinilShared
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Application delegate for the Adrafinil menu-bar app.
///
/// Drives the first-run setup window and the "While you were away" recap notification.
/// Crucially, it performs **no** privileged action at launch — everything that touches the
/// system (helper/daemon registration, CLI symlink, agent setup) is gated behind explicit
/// user action in `InstallerView`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    private var installerWindow: NSWindow?

    /// The hidden-icon fallback window. Owned strongly (with `isReleasedWhenClosed = false`) so ARC,
    /// not AppKit, balances its lifetime — a self-releasing window over-releases at the next
    /// autorelease-pool drain and crashes. Cleared in `windowWillClose`, so each present is fresh.
    private var menuWindow: NSWindow?

    /// The live delegate, so SwiftUI views can reach it without depending on `NSApp.delegate`
    /// (which, under `@NSApplicationDelegateAdaptor`, isn't guaranteed to be this concrete type).
    weak static var shared: AppDelegate?

    /// The live status model, set by `AdrafinilApp` at init, so AppKit-hosted windows (the
    /// hidden-icon menu window) render the same state as the menu-bar popover.
    static var sharedStatus: AppStatusModel?

    /// Drives the Dock icon: shown only while a real window (Settings, Setup) is open.
    private let dockVisibility = DockVisibilityController()

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self

        // Single instance. macOS blocks double-launch from Finder, but launching via Xcode (or a
        // different build path) bypasses that — and Xcode's Stop doesn't reliably kill a menu-bar
        // (LSUIElement) app, so old copies pile up. Terminate any other running instance on launch.
        terminateOtherInstances()

        // Be the notification delegate so the away recap shows as a banner even when Adrafinil
        // is the frontmost app (otherwise the system routes it silently to Notification Center).
        UNUserNotificationCenter.current().delegate = self

        // Show the Dock icon only while a real window is open (menu-bar app otherwise). Start before
        // any window is presented so the first-run Setup window promotes it.
        dockVisibility.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAwaySummary(_:)),
            name: .adrafinilAwaySummaryReceived,
            object: nil,
        )

        #if DEBUG
            // Daemon-free UI gallery: launch with `-ADRAFINIL_GALLERY 1` to review every surface/state.
            if UserDefaults.standard.bool(forKey: "ADRAFINIL_GALLERY") {
                presentGallery()
            } else {
                // Every DEBUG run opens the interactive control panel and skips the real first-run
                // flow, so the UI can be exercised with mock scenarios. Flip "Use live daemon" in
                // the panel to talk to the real daemon instead.
                presentDebugControlPanel()
            }
        #else
            // First run: present the setup flow and nothing else. No privileged work happens
            // until the user proceeds — helper/daemon registration, the CLI symlink, hook
            // installation, and the login item are all triggered by explicit buttons inside
            // InstallerView. On later launches the daemon is already registered with launchd and
            // starts on its own; the app simply connects to it (a failed connection before setup
            // is handled gracefully).
            if HelperInstaller.isFirstRun {
                presentInstaller()
            } else {
                // Self-heal the login item. `launchAtLogin` defaults on, but only setup and the
                // Settings toggle register it — so after an in-place update (or if it was never
                // registered) the menu-bar app wouldn't return on its own after a reboot.
                // Gated on setup having run: merely launching the app to look at the installer
                // must not register anything.
                if AdrafinilSettings.load().launchAtLogin, SMAppService.mainApp.status != .enabled {
                    try? SMAppService.mainApp.register()
                }

                // Adrafinil is active only while this app is open. Quitting pauses the daemon (see
                // `applicationShouldTerminate`), so resume here to undo a previous quit-pause —
                // reopening the app puts it back to work. Retried, since this launch can coincide
                // with the daemon adopting an updated binary (it restarts), and a resume lost to
                // that restart would otherwise leave Adrafinil stuck paused.
                Task { await DaemonClient.shared.resumeAtLaunch() }

                // Deliberately no window here when the icon is hidden. This branch also runs on a
                // launch-at-login auto-start (the default), and stealing focus with a centered
                // window on every login is exactly what a user who hid the icon does not want. The
                // way back in is re-activating the already-running app (Finder/Spotlight), which
                // arrives as `applicationShouldHandleReopen` — never as a cold login launch.
            }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Finder or Spotlight "re-launch" of the running instance. If a window (Settings, Setup, the
    /// menu window) is already up, front it. Otherwise, with the menu-bar icon hidden there is no
    /// surface at all — host the popover's contents in a real window so the app is never a dead
    /// end. (The old path, opening the Settings scene via the `showSettingsWindow:` selector,
    /// silently failed: that selector isn't in a menu-bar-only app's responder chain.) With the
    /// icon shown, the status item is the surface, so there's nothing to do.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows {
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        if !AdrafinilSettings.load().showInMenuBar {
            presentMenuWindow()
        }
        return true
    }

    /// Hosts the menu-bar popover's contents in a real window. Used when "Show in menu bar" is off:
    /// launching or reopening the app then has no status item to click, so this window is the way
    /// in — Settings and every action are reachable from it, and while it's open
    /// `DockVisibilityController` promotes the app to `.regular` (Dock icon, app menu, ⌘Q). No
    /// activation race or status-item reveal: it's an ordinary window.
    func presentMenuWindow() {
        guard let status = Self.sharedStatus else { return }
        if let existing = menuWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: MenuPopover(status: status))
        // Track SwiftUI's content size so tall states (a long agent list, an attention card, the
        // inline quit-confirm) resize the window instead of clipping against a fixed height.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Adrafinil" // for the window menu / accessibility only
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        // ARC owns it (see `menuWindow`); `windowWillClose` drops the reference so a close both
        // tears down the SwiftUI content (no stale quit-confirm, no background poll) and lets the
        // window deallocate cleanly.
        window.isReleasedWhenClosed = false
        window.delegate = self
        menuWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu-bar icon is back (re-enabled from Settings), so the fallback window is redundant —
    /// dismiss it and let the status item be the surface again.
    func closeMenuWindow() {
        menuWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === menuWindow {
            menuWindow = nil
        }
    }

    /// The single quit gate. Adrafinil is split across three executables (this app, the user
    /// daemon, the root helper), but the user shouldn't have to think about that — quitting should
    /// turn all of it off. The launchd services can't be force-killed (KeepAlive, and the helper is
    /// privileged) without re-triggering approval, so instead we pause the daemon — which releases
    /// every wake-lock and ignores agents until resumed — leaving the services registered but idle.
    /// `applicationDidFinishLaunching` resumes on the next launch, so "Adrafinil is active only
    /// while its app is open" holds. Centralizing here means every quit path (the popover's power
    /// button, ⌘Q from a window, logout) stops the daemon, not just the button.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Defer the actual exit until the daemon has been paused; quit anyway if it's unreachable
        // or unresponsive — `setPaused` is bounded by DaemonClient's call timeout, and the extra
        // race below keeps even a pathological hang from blocking logout/shutdown, where the
        // system gives apps only a few seconds before force-killing them.
        // (The uninstall flow doesn't come through here — it tears everything down and `exit()`s
        // directly, since there'd be no daemon left for this to reach.)
        Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let once = OnceResumer<Void> { cont.resume() }
                Task { @MainActor in
                    try? await DaemonClient.shared.setPaused(true)
                    once.resume(())
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.resume(()) }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        // Fix the content size on the SwiftUI root so the hosting controller's fitting size matches
        // (otherwise AppKit shrinks the window to a too-short height and clips the bottom button).
        let hosting = NSHostingController(rootView: InstallerView().frame(width: 560, height: 600))
        let window = NSWindow(contentViewController: hosting)
        // Modern, chromeless look: keep the traffic lights but hide the title text and make the
        // titlebar transparent. Not full-size-content — that pushed the content under the titlebar
        // and left an odd gap on steps without a hero image.
        window.title = "Adrafinil Setup" // for the window menu / accessibility only
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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
                rootView: InstallerView(setup: PreviewSetupProvider(), agentHooks: PreviewAgentHooksProvider()),
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
            window.setContentSize(NSSize(width: 1_180, height: 860))
            window.center()
            window.isReleasedWhenClosed = false
            galleryWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    #endif

    // MARK: - Away summary

    @objc
    private func handleAwaySummary(_ notification: Notification) {
        guard let summary = notification.object as? AwaySummary else { return }
        AwayNotifier.shared.deliver(summary)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the recap as a banner even while Adrafinil is the active app.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Routes a tap on the "service unavailable" alert to the matching fix: Login Items (to approve a
    /// registered-but-unapproved service) or the setup window (to register one that never was).
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        let action = response.notification.request.content.userInfo["adrafinilAction"] as? String
        if let action {
            Task { @MainActor in
                switch action {
                case "loginItems":
                    SMAppService.openSystemSettingsLoginItems()
                case "setup":
                    self.presentInstaller()
                default:
                    break
                }
            }
        }
        completionHandler()
    }
}
