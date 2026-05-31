import Foundation
import AdrafinilShared
import ServiceManagement
import AppKit

/// One service's registration outcome, surfaced in the installer's helper step.
struct SetupOutcome: Identifiable, Equatable {
    let name: String
    /// Non-nil when registration hard-failed; nil means enabled or pending approval.
    let failureMessage: String?
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
}

@MainActor
struct LiveSetupProvider: SetupProviding {
    var isFirstRun: Bool { HelperInstaller.isFirstRun }

    func installHelper() async -> [SetupOutcome] {
        await HelperInstaller.installIfNeeded().map { entry in
            if case .failed(let msg) = entry.result {
                return SetupOutcome(name: entry.name, failureMessage: msg)
            }
            return SetupOutcome(name: entry.name, failureMessage: nil)
        }
    }

    func symlinkCLI() async {
        await CLISymlinker.symlinkIfNeeded()
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
    func installHelper() async -> [SetupOutcome] {
        [SetupOutcome(name: "Helper", failureMessage: nil),
         SetupOutcome(name: "Daemon", failureMessage: nil)]
    }
    func symlinkCLI() async {}
    func uninstallEverything() async {}
}
#endif
