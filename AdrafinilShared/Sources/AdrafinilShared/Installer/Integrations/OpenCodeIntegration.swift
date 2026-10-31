import Foundation

/// OpenCode: a TS plugin at `~/.config/opencode/plugins/adrafinil.ts`. Detected by the `opencode`
/// binary on PATH.
struct OpenCodeIntegration: AgentIntegration {
    let agent = AgentKind.openCode

    /// Backstop TTL on each acquire, refreshed per turn. Like Pi's, it sits well above any real
    /// single turn, since TTL expiry releases even a busy session.
    static let holdTTLSeconds = 4 * 3_600

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

    /// Canonical OpenCode plugin. The hold is **turn-scoped**: acquire when a session starts
    /// working, release when it stops, and again when the session is deleted. Under `opencode serve`,
    /// `web` or `acp` one long-lived process hosts every session, so the process-exit watcher never
    /// fires and a per-session hold leaks until the backstop (issue #34); bracketing turns is right
    /// in the TUI too, where the Mac only needs to stay awake while the agent works.
    ///
    /// One file serves both plugin APIs through its `default` export. OpenCode 1.x reads `server()`,
    /// whose hooks receive `session.status` busy/idle (`retry` keeps the hold) with the id at
    /// `event.properties.sessionID`. OpenCode 2.x rejects a module without a default `{ id, setup }`
    /// and publishes no `session.status`; its `setup()` subscribes to `session.execution.started`
    /// and the three ends of a run, with the id at `event.data.sessionID`. Each API ignores the
    /// other's key: 1.x takes `server` from a default that has one, 2.x decodes `id` and `setup`.
    ///
    /// `held` keeps one acquire per busy stretch and makes a release without an acquire silent, and
    /// `queue` runs the CLI calls in order, so a short turn's release never overtakes its acquire.
    /// The release carries `--tool` or the key resolves to `unknown:<id>`. The 4h `--ttl` is the
    /// backstop for a missed end event, refreshed on each turn like the Pi extension's.
    private static func pluginTS(cliPath: String) -> String {
        """
        import { execFile } from "node:child_process"
        
        const held = new Set()
        let queue = Promise.resolve()
        const run = (args) =>
          (queue = queue.then(() => new Promise((done) => execFile(\(jsStringLiteral: cliPath), args, () => done()))))
        const acquire = (id) => {
          if (held.has(id)) return
          held.add(id)
          return run(["acquire", id, "--tool", "opencode", "--ttl", "\(holdTTLSeconds)"])
        }
        const release = (id) => {
          if (!held.delete(id)) return
          return run(["release", id, "--tool", "opencode"])
        }
        
        export default {
          id: "adrafinil",
          server: async () => ({
            event: async ({ event }) => {
              if (event.type === "session.deleted") return release(event.properties.info.id)
              if (event.type !== "session.status") return
              const status = event.properties.status.type
              if (status === "busy") return acquire(event.properties.sessionID)
              if (status === "idle") return release(event.properties.sessionID)
            }
          }),
          setup: async (ctx) => {
            const stop = new AbortController()
            const types = [
              "session.execution.started",
              "session.execution.succeeded",
              "session.execution.failed",
              "session.execution.interrupted",
              "session.deleted"
            ]
            void (async () => {
              for await (const event of ctx.event.subscribe({ types, signal: stop.signal })) {
                if (!event.data?.sessionID) continue
                if (event.type === "session.execution.started") await acquire(event.data.sessionID)
                else await release(event.data.sessionID)
              }
            })().catch(() => {})
            return () => stop.abort()
          }
        }
        """
    }
}
