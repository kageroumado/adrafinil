import Foundation

/// Pi: a TS extension at `~/.pi/agent/extensions/adrafinil.ts`. Detected by the `~/.pi` directory.
struct PiIntegration: AgentIntegration {
    let agent = AgentKind.pi

    /// Backstop TTL on each acquire, refreshed per turn (a re-acquire adopts the new expiry).
    /// TTL expiry releases unconditionally — even a CPU-busy tree — so this must sit safely above
    /// any real single agent run; with `--pid` attached, the dead-process and CPU-idle nets are the
    /// working cleanup and the TTL only catches the case where both lifecycle hooks were missed
    /// *and* no PID could attach (issue #26's 24-hour leak, capped to 4 hours).
    static let holdTTLSeconds = 4 * 3_600

    private func pluginRoot(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.pi/agent/extensions"
    }

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.pi")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.pi/agent/extensions/adrafinil.ts"
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
            content: { Self.extensionTS(cliPath: ctx.cliPath) },
            installSummary: "wrote Pi extension",
        )
    }

    /// Canonical Pi extension. Pi auto-discovers `.ts` extensions and calls `pi.on(<event>, handler)`
    /// from the default export. The hold is **turn-scoped**: `agent_start` acquires, `agent_settled`
    /// releases, and `session_shutdown` releases again as a safety net for a turn interrupted by
    /// exit. Pi has no session-id env var or stdin payload — the id is the session file path
    /// (`undefined` for ephemeral sessions, so fall back to the pid). Shells out via
    /// `node:child_process`, mirroring the OpenCode plugin.
    ///
    /// `agent_settled`, not `agent_end`: per Pi's own docs, after `agent_end` Pi may still auto-retry,
    /// auto-compact and retry, or drain queued follow-up messages — `agent_settled` is the event that
    /// means "Pi will not continue running automatically", which is exactly this hold's semantics.
    ///
    /// Bracketing the *session* instead (`session_start`/`session_shutdown`, shipped through 1.5.2)
    /// was wrong in both directions: the Mac stayed awake for the whole `pi` process lifetime
    /// including idle time at the prompt, and — since the only `acquire` was at t=0 — an idle release
    /// left the rest of the session unprotected with nothing to re-acquire. Re-acquiring per turn is
    /// safe because `acquire` is idempotent per key. (Issue #17.)
    ///
    /// `stdio: "ignore"` matters now that the safety-net release is routinely a no-op: `execFileSync`
    /// inherits stderr by default, so `release`'s "released nothing" would print into the TUI.
    ///
    /// The acquire carries `--pid` and `--ttl` (issue #26). Pi is a Node-hosted process — its
    /// executable path is Node's, so the CLI's executable-path parent walk can't find it and the
    /// hold used to sit with `pid=-1`, unreachable by the dead-process and CPU-idle nets; a missed
    /// `agent_settled` then leaked until the 24h backstop. Extensions load in-process (jiti import),
    /// so `process.pid` *is* the Pi host PID, whatever wrapper (npm, Homebrew, Nix) launched it —
    /// pass it explicitly and every net applies. The TTL is a second backstop for the residual
    /// missed-everything case, refreshed on each `agent_start` like the Cursor integration's.
    ///
    /// Device-verified against pi 0.83.0 (reporter, issue #17): the hold appears when a turn starts
    /// and is gone before the process exits, with no hold while sitting at the prompt.
    private static func extensionTS(cliPath: String) -> String {
        """
        import { execFileSync } from "node:child_process"
        
        function run(args) {
          try { execFileSync(\(swiftStringLiteral: cliPath), args, { stdio: "ignore" }) } catch (_) {}
        }
        
        export default function (pi) {
          const id = (ctx) => ctx?.sessionManager?.getSessionFile?.() ?? String(process.pid)
          pi.on("agent_start", async (_event, ctx) =>
            run(["acquire", id(ctx), "--tool", "pi", "--pid", String(process.pid), "--ttl", "\(holdTTLSeconds)"]))
          pi.on("agent_settled", async (_event, ctx) => run(["release", id(ctx), "--tool", "pi"]))
          pi.on("session_shutdown", async (_event, ctx) => run(["release", id(ctx), "--tool", "pi"]))
        }
        """
    }
}

private extension DefaultStringInterpolation {
    /// Emits `item` as a double-quoted JS string literal with proper escaping (JSON string
    /// encoding is a subset of JS), so quotes or backslashes in the bundle path can't break the
    /// generated extension.
    mutating func appendInterpolation(swiftStringLiteral item: String) {
        if let data = try? JSONSerialization.data(withJSONObject: item, options: .fragmentsAllowed),
           let literal = String(data: data, encoding: .utf8) {
            appendInterpolation(literal)
        } else {
            appendInterpolation("\"\(item)\"")
        }
    }
}
