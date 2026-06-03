import Foundation

/// Codex: `~/.codex/hooks.json`, `SessionStart` → acquire. Release rides the daemon's
/// process-exit watcher, not a hook, because Codex's hook model differs from Claude's (verified
/// against the Codex 0.136.0 binary on this machine):
///
/// 1. **Flat config shape.** Codex copied Claude Code's hook *event* model (SessionStart,
///    PreToolUse, …) and stdin payload, but its `hooks.json` is *flatter*: each event maps to a
///    plain array of `HookHandlerConfig`, so a command hook is `{ "type": "command", "command": …
///    }` directly — no inner `hooks` wrapper. `CodexHookShape` writes that shape; using Claude's
///    nested one would fail Codex's strict deserialization.
/// 2. **No session-end hook.** `Stop` fires per *turn*, not at session end, and there is no
///    session-end event. Installing a `Stop` → release would drop the assertion after the first
///    turn. So Adrafinil acquires on `SessionStart` and releases on process exit, keyed by session id.
/// 3. **Hooks only fire in the interactive TUI — not `codex exec`.** The non-interactive path
///    doesn't engage the hook runtime at all (confirmed: `codex exec` ignores `hooks.json`
///    entirely), so for `codex exec` capture relies on the daemon's process-sniffing — it sees the
///    `codex` process and auto-acquires, with the same exit release.
/// 4. **Hook trust.** Codex won't run a command hook until its exact definition is trusted
///    (a `trusted_hash` stamped via `/hooks` in the TUI). Adrafinil can't trust on the user's
///    behalf, so the installer surfaces that the user must open Codex and trust the hook, and
///    re-install preserves an already-trusted entry rather than clobbering its hash.
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
        try shape(ctx).install(dryRun: dryRun)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try shape(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        shape(ctx).installState()
    }

    private func shape(_ ctx: HookContext) -> CodexHookShape {
        CodexHookShape(
            configPath: "\(ctx.homeRoot)/.codex/hooks.json",
            event: "SessionStart",
            command: ctx.hookCommand("acquire", tool: agent.rawValue),
        )
    }
}
