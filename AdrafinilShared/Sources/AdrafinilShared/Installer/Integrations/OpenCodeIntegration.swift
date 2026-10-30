import Foundation

/// OpenCode: a TS plugin at `~/.config/opencode/plugins/adrafinil.ts`. Detected by the `opencode`
/// binary on PATH.
struct OpenCodeIntegration: AgentIntegration {
    let agent = AgentKind.openCode

    private func pluginRoot(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.config/opencode/plugins"
    }

    func isDetected(_: HookContext) -> Bool {
        binaryOnPath("opencode")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.config/opencode/plugins/adrafinil.ts"
    }

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
            installSummary: "wrote OpenCode plugin",
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
    ///
    /// Under `opencode serve` one long-lived process hosts every session, so the process-exit
    /// watcher never fires and per-session holds leak until the 24h backstop. In that mode the
    /// plugin holds per turn instead: acquire when `session.status` goes busy, release when it
    /// goes idle (or the session is deleted).
    private static func pluginTS(cliPath: String) -> String {
        // The path lands inside a JS template literal AND a shell double-quoted string, so
        // backslashes, backticks, `$` (template interpolation), and quotes all need escaping.
        let escaped = cliPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        export const Adrafinil = async ({ $ }) => {
          const server = process.argv.includes("serve")
          const held = new Set()
          const release = async (id) => {
            if (!held.delete(id)) return
            await $`"\(escaped)" release ${id} --tool opencode`.quiet().nothrow()
          }
          return {
            event: async ({ event }) => {
              if (!server) {
                if (event.type === "session.created") await $`"\(escaped)" acquire ${event.properties.info.id} --tool opencode`
                return
              }
              if (event.type === "session.deleted") return release(event.properties.info.id)
              if (event.type !== "session.status") return
              const id = event.properties.sessionID
              const status = event.properties.status.type
              if (status === "idle") return release(id)
              if (status !== "busy" || held.has(id)) return
              held.add(id)
              await $`"\(escaped)" acquire ${id} --tool opencode --ttl 14400`.quiet().nothrow()
            }
          }
        }
        """
    }
}
