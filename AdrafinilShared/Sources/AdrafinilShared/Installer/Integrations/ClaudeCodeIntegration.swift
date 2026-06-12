import Foundation

/// Claude Code: `~/.claude/settings.json`, `UserPromptSubmit` → acquire, `Stop` → release.
///
/// **Activity-scoped, not session-scoped.** An earlier version wired `SessionStart`/`SessionEnd`,
/// which held a sleep block for the *entire* session — including all the time it sat idle at the
/// prompt waiting for input. Claude Code instead brackets each working turn: `UserPromptSubmit`
/// fires when a prompt is submitted and `Stop` fires when the agent finishes responding
/// (`reason: 'completed'` in the query loop). Acquiring/releasing on those means the Mac is only
/// kept awake while the agent is actually working, and an open-but-idle session lets it sleep.
///
/// An Esc-interrupt is the one turn-end that fires no `Stop` (the abort short-circuits it), and Claude
/// Code has no interrupt hook. The reliable catch is the daemon's CPU-idle sweep — an interrupted
/// session's process tree drops to ~idle, and the sweep releases it after the idle window. The third
/// hook here, `Notification` matched to `idle_prompt`, is a *best-effort fast-path*: when Claude does
/// emit its "waiting for your input" notification it releases sooner, but that notification is gated
/// by version/focus/notification-channel and often doesn't fire, so it is not relied upon. The
/// process-exit watcher covers a terminal closed mid-turn. None of these need a session-end hook.
///
/// Claude Code is the only agent that also exposes a real session-id env var to hooks —
/// `CLAUDE_CODE_SESSION_ID` (verified against 2.1.158; *not* `CLAUDE_SESSION_ID`, which expands
/// empty). The CLI still prefers the `session_id` field from the hook's stdin JSON; the env-var
/// positional is a fallback. The same session id keys both hooks, so multi-turn sessions cycle
/// acquire→release→acquire on one idempotent key.
struct ClaudeCodeIntegration: AgentIntegration {
    let agent = AgentKind.claudeCode

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.claude")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.claude/settings.json"
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

    private func shape(_ ctx: HookContext) -> NestedJSONHookShape {
        NestedJSONHookShape(
            configPath: "\(ctx.homeRoot)/.claude/settings.json",
            startEvent: "UserPromptSubmit",
            endEvent: "Stop",
            acquireCommand: ctx.hookCommand("acquire", tool: agent.rawValue, sessionVar: "$CLAUDE_CODE_SESSION_ID"),
            releaseCommand: ctx.hookCommand("release", tool: agent.rawValue, sessionVar: "$CLAUDE_CODE_SESSION_ID"),
            obsoleteEvents: ["SessionStart", "SessionEnd"],
            extraReleases: [.init(event: "Notification", matcher: "idle_prompt")],
        )
    }

    /// MCP lives in the global `~/.claude.json` (`mcpServers`, user scope) — verified against a real
    /// install: existing entries are `{"type":"stdio","command":…,"args":[…]}`.
    func mcpShape(_ ctx: HookContext) -> MCPServerShape? {
        MCPServerShape(
            configPath: "\(ctx.homeRoot)/.claude.json",
            serverName: HookContext.mcpServerName,
            entry: ctx.mcpEntry(tool: agent.rawValue),
        )
    }
}
