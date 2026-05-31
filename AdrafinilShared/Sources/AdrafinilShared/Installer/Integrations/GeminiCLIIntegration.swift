import Foundation

/// Gemini CLI: `~/.gemini/settings.json`, `SessionStart` → acquire, `SessionEnd` → release. Same
/// nested JSON shape as Claude Code, but no session-id env var — the CLI reads `session_id` from
/// the hook's stdin.
struct GeminiCLIIntegration: AgentIntegration {
    let agent = AgentKind.geminiCLI

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.gemini")
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
            configPath: "\(ctx.homeRoot)/.gemini/settings.json",
            startEvent: "SessionStart",
            endEvent: "SessionEnd",
            acquireCommand: ctx.hookCommand("acquire", tool: agent.rawValue),
            releaseCommand: ctx.hookCommand("release", tool: agent.rawValue)
        )
    }
}
