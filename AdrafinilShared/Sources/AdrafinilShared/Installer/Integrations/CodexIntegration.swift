import Foundation

/// Codex: `~/.codex/hooks.json`, `SessionStart` → acquire. Release rides the daemon's
/// process-exit watcher, not a hook, because Codex's hook model differs from Claude's (verified
/// against Codex 0.135.0 on a real device):
///
/// 1. **No session-end hook.** `Stop` fires per *turn*, not at session end, and there is no
///    session-end event. Installing a `Stop` → release would drop the assertion after the first
///    turn. So Adrafinil acquires on `SessionStart` and releases on process exit, keyed by session id.
/// 2. **Hooks only fire in the interactive TUI — not `codex exec`.** The non-interactive path
///    doesn't engage the hook runtime at all, so for `codex exec` capture relies on the daemon's
///    process-sniffing (it sees the `codex` process and auto-acquires, with the same exit release).
/// 3. **Hook trust.** Codex won't run a command hook until its exact definition is trusted
///    (hash-based) via `/hooks` in the TUI. Adrafinil can't trust on the user's behalf, so the
///    installer surfaces that the user must open Codex and trust the Adrafinil hook.
///
/// Codex exposes no session-id env var (it has `CODEX_THREAD_ID`, not `CODEX_SESSION_ID`, and
/// documents only the stdin field), so the command carries no positional key — the CLI reads
/// `session_id` from stdin.
struct CodexIntegration: AgentIntegration {
    let agent = AgentKind.codex

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.codex")
    }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let result = try shape(ctx).install(dryRun: dryRun)
        return HookInstaller.InstallResult(
            summary: result.summary + "; trust it in Codex with /hooks",
            diff: result.diff
        )
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try shape(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        shape(ctx).installState()
    }

    private func shape(_ ctx: HookContext) -> NestedJSONHookShape {
        NestedJSONHookShape(
            configPath: "\(ctx.homeRoot)/.codex/hooks.json",
            startEvent: "SessionStart",
            endEvent: nil,
            acquireCommand: ctx.hookCommand("acquire", tool: agent.rawValue),
            releaseCommand: ctx.hookCommand("release", tool: agent.rawValue)
        )
    }
}
