import AdrafinilShared
import AppKit
import Foundation
import ServiceManagement

/// One service's registration outcome, surfaced in the installer's helper step.
struct SetupOutcome: Identifiable, Equatable {
    let name: String
    /// Non-nil when registration hard-failed.
    let failureMessage: String?
    /// `true` when the service registered but the user must still approve it in System Settings →
    /// Login Items before it enables. The installer surfaces this with guidance instead of silently
    /// advancing.
    var requiresApproval: Bool = false
    var id: String {
        name
    }
}

/// First-run setup operations: register the privileged services, symlink the CLI, and the full
/// teardown. Live wraps `HelperInstaller` / `CLISymlinker` / `SMAppService` / `HookInstaller`;
/// previews inject a no-op stub so the installer flow can be walked without touching the system.
@MainActor
protocol SetupProviding {
    var isFirstRun: Bool { get }
    func installHelper() async -> [SetupOutcome]
    /// Whether both background services are currently enabled — polled while the installer waits
    /// for the user's approval in System Settings.
    func servicesEnabled() -> Bool
    func symlinkCLI() async
    /// Post-setup follow-ups (e.g. requesting notification permission for the away recap, in
    /// context rather than mid-unlock at the first recap).
    func didFinishSetup()
    /// Tears everything down. Returns human-readable problems that need manual cleanup — e.g.
    /// an agent config that couldn't be parsed, whose hooks would otherwise silently outlive
    /// the CLI binary they invoke.
    func uninstallEverything() async -> [String]
    /// Opens System Settings → Login Items so the user can approve a pending background service.
    func openLoginItems()
}

@MainActor
struct LiveSetupProvider: SetupProviding {
    var isFirstRun: Bool {
        HelperInstaller.isFirstRun
    }

    func installHelper() async -> [SetupOutcome] {
        await HelperInstaller.installIfNeeded().map { entry in
            switch entry.result {
            case let .failed(msg):
                SetupOutcome(name: entry.name, failureMessage: msg)
            case .pendingApproval:
                SetupOutcome(name: entry.name, failureMessage: nil, requiresApproval: true)
            case .enabled:
                SetupOutcome(name: entry.name, failureMessage: nil)
            }
        }
    }

    func servicesEnabled() -> Bool {
        SMAppService.daemon(plistName: "LaunchDaemon.plist").status == .enabled
            && SMAppService.agent(plistName: "LaunchAgent.plist").status == .enabled
    }

    func symlinkCLI() async {
        await CLISymlinker.symlinkIfNeeded()
    }

    func didFinishSetup() {
        AwayNotifier.shared.requestAuthorizationUpfront()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func uninstallEverything() async -> [String] {
        var issues: [String] = []

        // Pause first: a paused daemon rejects acquires, so a still-running agent hook firing
        // between the release below and the unregister can't re-set `disablesleep` right before
        // the components that would clear it are torn down.
        try? await DaemonClient.shared.setPaused(true)
        // Clear the sleep block *before* tearing down the helper. `disablesleep` persists in the
        // power-management prefs and nothing in powerd clears it on the setter's death — so once the
        // helper is unregistered, a still-set block would leave the Mac unable to sleep with no
        // component left to fix it. forceReleaseAll drives the helper to clear it and awaits that.
        try? await DaemonClient.shared.forceReleaseAll()

        // Hooks that can't be cleaned must be reported, not swallowed: they would keep invoking a
        // CLI binary that's about to disappear, failing loudly on the agent's every turn.
        let installer = HookInstaller(cliPath: CLISymlinker.hookCLIPath)
        for kind in AgentKind.allCases {
            do {
                _ = try installer.uninstall(for: kind)
            } catch HookInstaller.SkipReason.notInstalled {
                // Not present on this system — nothing to clean.
            } catch {
                issues.append("\(kind.displayName): \(error.localizedDescription)")
            }
            // Also pull our MCP server from agents that have it, so we don't leave an `adrafinil`
            // entry pointing at a CLI we're about to delete. No-op for agents without MCP support.
            do {
                _ = try installer.uninstallMCP(for: kind)
            } catch HookInstaller.SkipReason.notInstalled {
            } catch {
                issues.append("\(kind.displayName) MCP entry: \(error.localizedDescription)")
            }
        }

        try? await SMAppService.daemon(plistName: "LaunchDaemon.plist").unregister()
        try? await SMAppService.agent(plistName: "LaunchAgent.plist").unregister()
        // The app itself is a login item too — leaving it registered would resurrect the
        // just-uninstalled app at the next login, straight into the setup flow.
        try? await SMAppService.mainApp.unregister()

        if let path = CLISymlinker.installedCLIPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Remove Adrafinil's own data directory — config.json, events.log, and the CLI socket — now
        // that nothing is left to use it (done after unregistering the daemon, which owns the socket,
        // and after forceReleaseAll above, which needed it). Leaves no settings or logs behind.
        try? FileManager.default.removeItem(at: AdrafinilConstants.appSupportURL)

        // Reset first-run so relaunching the bundle walks guided Setup fresh, rather than coming up as
        // a half-configured app with no services registered.
        HelperInstaller.resetFirstRun()
        return issues
    }
}

#if DEBUG
    /// A no-op `SetupProviding` for previews/gallery — reports success without registering anything.
    @MainActor
    struct PreviewSetupProvider: SetupProviding {
        var isFirstRun: Bool = true
        /// Drives a preview of the "needs approval" guidance in the installer's helper step.
        var simulateApproval: Bool = false
        func installHelper() async -> [SetupOutcome] {
            [
                SetupOutcome(name: "Helper", failureMessage: nil, requiresApproval: simulateApproval),
                SetupOutcome(name: "Daemon", failureMessage: nil, requiresApproval: simulateApproval),
            ]
        }
        func servicesEnabled() -> Bool {
            !simulateApproval
        }
        func symlinkCLI() async {}
        func didFinishSetup() {}
        func uninstallEverything() async -> [String] {
            []
        }
        func openLoginItems() {}
    }
#endif
