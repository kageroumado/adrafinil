import Foundation

/// Crush: `~/.config/crush/crush.json`. Crush exposes only a `PreToolUse` hook, so Adrafinil uses
/// it to `acquire` and relies on the daemon's process-exit watcher for release. Detected by the
/// `crush` binary on PATH (no well-known config directory to probe). Crush provides the session id
/// in `$CRUSH_SESSION_ID`.
struct CrushIntegration: AgentIntegration {
    let agent = AgentKind.crush

    func isDetected(_ ctx: HookContext) -> Bool { binaryOnPath("crush") }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try shape(ctx).install(dryRun: dryRun)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try shape(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        shape(ctx).installState()
    }

    private func shape(_ ctx: HookContext) -> FlatJSONHookShape {
        FlatJSONHookShape(
            configPath: "\(ctx.homeRoot)/.config/crush/crush.json",
            entries: [
                (event: "PreToolUse", command: ctx.hookCommand("acquire", tool: agent.rawValue, sessionVar: "$CRUSH_SESSION_ID"))
            ],
            installSummary: "wired PreToolUse hook (release via process-exit watcher)",
            uninstallSummary: "removed Crush hook entry"
        )
    }
}
