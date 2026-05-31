import Foundation

/// Claude Code: `~/.claude/settings.json`, `SessionStart` → acquire, `SessionEnd` → release.
///
/// Claude Code is the only agent that also exposes a real session-id env var to hooks —
/// `CLAUDE_CODE_SESSION_ID` (verified against 2.1.158; *not* `CLAUDE_SESSION_ID`, which expands
/// empty). The CLI still prefers the `session_id` field from the hook's stdin JSON; the env-var
/// positional is a fallback.
struct ClaudeCodeIntegration: AgentIntegration {
    let agent = AgentKind.claudeCode

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.claude")
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
            startEvent: "SessionStart",
            endEvent: "SessionEnd",
            acquireCommand: ctx.hookCommand("acquire", tool: agent.rawValue, sessionVar: "$CLAUDE_CODE_SESSION_ID"),
            releaseCommand: ctx.hookCommand("release", tool: agent.rawValue, sessionVar: "$CLAUDE_CODE_SESSION_ID")
        )
    }
}
