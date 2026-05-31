import Foundation

/// OpenCode: a TS plugin at `~/.config/opencode/plugins/adrafinil.ts`. Detected by the `opencode`
/// binary on PATH.
struct OpenCodeIntegration: AgentIntegration {
    let agent = AgentKind.openCode

    private func pluginRoot(_ ctx: HookContext) -> String { "\(ctx.homeRoot)/.config/opencode/plugins" }

    func isDetected(_ ctx: HookContext) -> Bool { binaryOnPath("opencode") }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try plugin(ctx).install(dryRun: dryRun)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try plugin(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        plugin(ctx).installState()
    }

    private func plugin(_ ctx: HookContext) -> FilePlugin {
        FilePlugin(
            pluginRoot: pluginRoot(ctx),
            fileName: "adrafinil.ts",
            content: { Self.pluginTS(cliPath: ctx.cliPath) },
            installSummary: "wrote OpenCode plugin"
        )
    }

    /// Canonical OpenCode plugin. Acquire on `session.created` only — `session.idle` fires per-turn
    /// (every time the agent finishes responding, not at session end), so releasing on it would
    /// drop the assertion mid-session (the same trap as Codex's per-turn `Stop`). Release instead
    /// rides the daemon's process-exit watcher when the `opencode` process exits. The session id is
    /// `event.properties.info.id` for `session.created` (the `Session` object).
    ///
    /// Device-verified against opencode 1.2.17: plugins load from `~/.config/opencode/plugins/`
    /// (plural), `({ $ })` and `({ event })` destructuring work, and this exact plugin fired
    /// `acquire ses_… --tool opencode` on `session.created`.
    private static func pluginTS(cliPath: String) -> String {
        """
        export const Adrafinil = async ({ $ }) => {
          return {
            event: async ({ event }) => {
              if (event.type === "session.created") await $`\(cliPath) acquire ${event.properties.info.id} --tool opencode`
            }
          }
        }
        """
    }
}
