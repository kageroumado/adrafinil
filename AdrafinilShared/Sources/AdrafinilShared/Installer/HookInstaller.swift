import Foundation

/// Writes (or removes) Adrafinil hook entries inside each agent's config file.
///
/// Atomic per-file. Always reads → mutates → writes a copy. Preserves any
/// non-Adrafinil hook entries the user has installed.
public struct HookInstaller {
    public enum SkipReason: Error {
        case notInstalled
        case unsupportedHere(String)
    }

    public struct InstallResult {
        public let summary: String
        public let diff: String

        public init(summary: String, diff: String) {
            self.summary = summary
            self.diff = diff
        }
    }

    /// Absolute path to the adrafinil CLI binary. Embedded in the hook commands.
    public let cliPath: String

    /// Filesystem root for `~` expansion. Production uses `NSHomeDirectory()`; tests inject a temp dir.
    public let homeRoot: String

    public init(cliPath: String, homeRoot: String = NSHomeDirectory()) {
        self.cliPath = cliPath
        self.homeRoot = homeRoot
    }

    public func install(for agent: AgentKind, dryRun: Bool) throws -> InstallResult {
        let spec = HookSpec.for(agent: agent, cliPath: cliPath, homeRoot: homeRoot)
        guard spec.isDetected() else { throw SkipReason.notInstalled }
        return try spec.install(dryRun: dryRun)
    }

    /// Removes Adrafinil hook entries for `agent`.
    ///
    /// When `dryRun` is `true` the method computes what would change and returns an
    /// `InstallResult` describing the diff without writing anything to disk.
    @discardableResult
    public func uninstall(for agent: AgentKind, dryRun: Bool = false) throws -> InstallResult {
        let spec = HookSpec.for(agent: agent, cliPath: cliPath, homeRoot: homeRoot)
        return try spec.uninstall(dryRun: dryRun)
    }

    /// Returns a list of agents currently detected on the system.
    public static func detectedAgents(homeRoot: String = NSHomeDirectory()) -> [AgentKind] {
        AgentKind.allCases.filter { kind in
            HookSpec.for(agent: kind, cliPath: "", homeRoot: homeRoot).isDetected()
        }
    }

    /// Returns the hook-installation state for `agent` (SPEC §7.2 — used by Settings → Agents tab).
    ///
    /// - `.notInstalled` — no Adrafinil entry found in the agent's config.
    /// - `.installed` — an Adrafinil entry exists and matches what `install()` would write.
    /// - `.modifiedExternally` — an Adrafinil-tagged entry exists but differs from the canonical form.
    public func installState(for agent: AgentKind) -> HookInstallState {
        let spec = HookSpec.for(agent: agent, cliPath: cliPath, homeRoot: homeRoot)
        return spec.installState()
    }
}
