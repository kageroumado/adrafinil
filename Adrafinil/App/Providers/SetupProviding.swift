import Foundation
import AdrafinilShared
import ServiceManagement
import AppKit

/// One service's registration outcome, surfaced in the installer's helper step.
struct SetupOutcome: Identifiable, Equatable {
    let name: String
    /// Non-nil when registration hard-failed.
    let failureMessage: String?
    /// `true` when the service registered but the user must still approve it in System Settings →
    /// Login Items before it enables. The installer surfaces this with guidance instead of silently
    /// advancing.
    var requiresApproval: Bool = false
    var id: String { name }
}

/// First-run setup operations: register the privileged services, symlink the CLI, and the full
/// teardown. Live wraps `HelperInstaller` / `CLISymlinker` / `SMAppService` / `HookInstaller`;
/// previews inject a no-op stub so the installer flow can be walked without touching the system.
@MainActor
protocol SetupProviding {
    var isFirstRun: Bool { get }
    func installHelper() async -> [SetupOutcome]
    func symlinkCLI() async
    func uninstallEverything() async
    /// Opens System Settings → Login Items so the user can approve a pending background service.
    func openLoginItems()
}

@MainActor
struct LiveSetupProvider: SetupProviding {
    var isFirstRun: Bool { HelperInstaller.isFirstRun }

    func installHelper() async -> [SetupOutcome] {
        await HelperInstaller.installIfNeeded().map { entry in
            switch entry.result {
            case .failed(let msg):
                return SetupOutcome(name: entry.name, failureMessage: msg)
            case .pendingApproval:
                return SetupOutcome(name: entry.name, failureMessage: nil, requiresApproval: true)
            case .enabled:
                return SetupOutcome(name: entry.name, failureMessage: nil)
            }
        }
    }

    func symlinkCLI() async {
        await CLISymlinker.symlinkIfNeeded()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func uninstallEverything() async {
        // Clear the sleep block *before* tearing down the helper. `disablesleep` persists in the
        // power-management prefs and nothing in powerd clears it on the setter's death — so once the
        // helper is unregistered, a still-set block would leave the Mac unable to sleep with no
        // component left to fix it. forceReleaseAll drives the helper to clear it and awaits that.
        try? await DaemonClient().forceReleaseAll()

        let installer = HookInstaller(
            cliPath: CLISymlinker.installedCLIPath ?? CLISymlinker.bundledCLIPath ?? "adrafinil"
        )
        for kind in AgentKind.allCases {
            try? installer.uninstall(for: kind)
            // Also pull our MCP server from agents that have it, so we don't leave an `adrafinil`
            // entry pointing at a CLI we're about to delete. No-op for agents without MCP support.
            try? installer.uninstallMCP(for: kind)
        }

        try? await SMAppService.daemon(plistName: "LaunchDaemon.plist").unregister()
        try? await SMAppService.agent(plistName: "LaunchAgent.plist").unregister()

        if let path = CLISymlinker.installedCLIPath {
            try? FileManager.default.removeItem(atPath: path)
        }
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
        [SetupOutcome(name: "Helper", failureMessage: nil, requiresApproval: simulateApproval),
         SetupOutcome(name: "Daemon", failureMessage: nil, requiresApproval: simulateApproval)]
    }
    func symlinkCLI() async {}
    func uninstallEverything() async {}
    func openLoginItems() {}
}
#endif
