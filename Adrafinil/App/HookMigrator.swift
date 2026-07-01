import AdrafinilShared
import Foundation

/// Runs the once-per-build hook migration: when Adrafinil ships a new hook *shape* (e.g. Codex's
/// `Stop` release added alongside the `UserPromptSubmit` acquire), an existing user's on-disk config
/// is in the old shape until they re-run setup. On the first launch of a new build this reinstalls the
/// hooks for every agent Adrafinil already manages, so the upgrade self-heals. Reinstall is idempotent
/// and trust-preserving, so it's safe; the pure gating lives in `HookMigration` (unit-tested).
@MainActor
enum HookMigrator {
    /// Reinstalls managed hooks if this build hasn't migrated yet. Returns the agents reinstalled
    /// (empty when nothing was due). Records the build whenever it changed — even with nothing to
    /// reinstall — so a no-op bump still advances the marker and won't re-run next launch.
    @discardableResult
    static func runIfNeeded(
        agentHooks: any AgentHooksProviding,
        currentBuild: String = bundleBuild,
        isFirstRun: Bool = HelperInstaller.isFirstRun,
        defaults: UserDefaults = .standard,
    ) -> [AgentKind] {
        let lastBuild = defaults.string(forKey: HookMigration.lastBuildDefaultsKey)
        let states = agentHooks.detectedAgents().map { (agent: $0, state: agentHooks.installState(for: $0)) }
        let toReinstall = HookMigration.agentsToReinstall(
            lastBuild: lastBuild, currentBuild: currentBuild, isFirstRun: isFirstRun, states: states,
        )
        if lastBuild != currentBuild {
            defaults.set(currentBuild, forKey: HookMigration.lastBuildDefaultsKey)
        }
        var reinstalled: [AgentKind] = []
        for agent in toReinstall {
            do {
                try agentHooks.install(for: agent)
                reinstalled.append(agent)
            } catch {
                // Leave it: the drift card / Codex trust note still nudges the user to reconnect.
            }
        }
        return reinstalled
    }

    /// The running build (CFBundleVersion), falling back to the marketing version if absent.
    static var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? AdrafinilConstants.marketingVersion
    }
}
