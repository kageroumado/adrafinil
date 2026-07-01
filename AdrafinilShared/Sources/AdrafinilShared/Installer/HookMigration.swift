import Foundation

/// Pure decision logic for the once-per-build hook migration.
///
/// When Adrafinil changes the *shape* of an agent's hooks (e.g. Codex gaining a `Stop` release
/// alongside the `UserPromptSubmit` acquire), an existing user's on-disk config is left in the old
/// shape until they happen to re-run setup. This decides — given the last build that migrated, the
/// current build, whether this is first-run, and each detected agent's install state — which agents
/// to reinstall so the upgrade self-heals. Reinstalling is idempotent and trust-preserving
/// (`CodexHookShape` keeps correct handlers byte-stable), so it's safe to run across all managed
/// agents. The app wrapper supplies the real `UserDefaults` and `install` calls; this stays pure so
/// the gating is unit-tested without disk or a bundle version.
public enum HookMigration {
    /// Key under which the app records the last build it migrated (in `UserDefaults`).
    public static let lastBuildDefaultsKey = "HookMigration.lastBuild"

    /// Agents to reinstall for this launch, or `[]` when no migration is due.
    ///
    /// - Returns `[]` when the build hasn't changed since the last migration (the common case) or on
    ///   first run (the installer is about to set up current hooks — nothing to migrate; the caller
    ///   still records the build so the next launch is a no-op).
    /// - Otherwise returns every detected agent we currently manage (`.installed` or
    ///   `.modifiedExternally`), skipping agents we don't manage (`.notInstalled`) or can't safely
    ///   touch (`.configUnreadable`).
    public static func agentsToReinstall(
        lastBuild: String?,
        currentBuild: String,
        isFirstRun: Bool,
        states: [(agent: AgentKind, state: HookInstallState)],
    ) -> [AgentKind] {
        guard lastBuild != currentBuild, !isFirstRun else { return [] }
        return states.compactMap { agent, state in
            switch state {
            case .installed, .modifiedExternally: agent
            case .notInstalled, .configUnreadable: nil
            }
        }
    }
}
