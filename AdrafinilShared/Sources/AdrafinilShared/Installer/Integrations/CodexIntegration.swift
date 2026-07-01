import Foundation

/// Codex: `~/.codex/hooks.json`, `UserPromptSubmit` → acquire, `Stop` → release (verified against
/// codex-rs source and on-device against npm `@openai/codex`):
///
/// 1. **Nested matcher-group config shape.** Codex copied Claude Code's hook *event* model
///    (SessionStart, UserPromptSubmit, PreToolUse, Stop, …), stdin payload, *and* its nested
///    `hooks.json` structure: each event maps to an array of matcher groups, each wrapping an inner
///    `hooks` array of `{ "type": "command", "command": … }`. `CodexHookShape` writes that; the flat
///    (no-wrapper) form is silently ignored — it never appears in `/hooks` and can't be trusted.
/// 2. **`UserPromptSubmit`, not `SessionStart`.** `SessionStart` fires only on a *brand-new* session —
///    Codex resumes the last conversation by default, and a resume does **not** fire it (verified
///    live), so a `SessionStart` hook silently misses most real usage. `UserPromptSubmit` fires on
///    every prompt submission, new session or resumed, so the Mac is kept awake whenever the user
///    actually sets Codex working. Acquiring per-turn on a session-id-keyed idempotent hold mirrors
///    Claude Code.
/// 3. **`Stop` releases at turn end.** Codex's `Stop` hook fires when a turn completes and control
///    returns to the user (`run_turn_stop_hooks` runs only when `!needs_follow_up`; codex-rs
///    `session/turn.rs`), carrying the same `session_id` on stdin that acquire keys on. So
///    acquire→release brackets each turn exactly like Claude Code, instead of leaning on the daemon's
///    CPU-idle sweep to notice the tree went quiet. The sweep + process-exit watcher remain as
///    backstops for the one turn-end that fires no `Stop` — an Esc-interrupt, whose abort
///    short-circuits the stop hooks — and for installs the daemon can't process-watch.
/// 4. **Hooks only fire in the interactive TUI — not `codex exec`.** The non-interactive path doesn't
///    engage the hook runtime at all (confirmed: `codex exec` ignores `hooks.json` entirely), so for
///    `codex exec` capture relies on the daemon's process-sniffing — it sees the `codex` process and
///    auto-acquires, with the same exit release.
/// 5. **Hook trust.** Codex won't run a command hook until it's trusted — the user runs `/hooks` in
///    the TUI and Codex stamps a `trusted_hash` into `config.toml` keyed per handler by its position
///    and command. Adrafinil can't trust on the user's behalf, so the installer surfaces that step,
///    and re-install leaves an already-correct handler in place so the trust hash keeps matching.
///    Each event is trusted independently, so the `Stop` handler is a single extra one-time approval.
///
/// Codex exposes no session-id env var (it has `CODEX_THREAD_ID`, not `CODEX_SESSION_ID`, and
/// documents only the stdin field), so both commands carry no positional key — the CLI reads
/// `session_id` from stdin for acquire and release alike.
struct CodexIntegration: AgentIntegration {
    let agent = AgentKind.codex

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.codex")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.codex/hooks.json"
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
            acquireEvent: "UserPromptSubmit",
            acquireCommand: ctx.hookCommand("acquire", tool: agent.rawValue),
            releaseEvent: "Stop",
            releaseCommand: ctx.hookCommand("release", tool: agent.rawValue),
            obsoleteEvents: ["SessionStart"],
        )
    }
}
