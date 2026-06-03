import Foundation

/// Cursor: `~/.cursor/hooks.json`, `sessionStart` → acquire, `sessionEnd` → release. Cursor uses a
/// flatter shape than Claude (`{"command": …}` entries directly, no inner `hooks` wrapper) and a
/// `version` field on a fresh file. No `CURSOR_SESSION_ID` env var exists — Cursor passes
/// `session_id` on the hook's stdin.
struct CursorIntegration: AgentIntegration {
    let agent = AgentKind.cursor

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.cursor") ||
            FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
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

    private func shape(_ ctx: HookContext) -> FlatJSONHookShape {
        FlatJSONHookShape(
            configPath: "\(ctx.homeRoot)/.cursor/hooks.json",
            entries: [
                (event: "sessionStart", command: ctx.hookCommand("acquire", tool: agent.rawValue)),
                (event: "sessionEnd", command: ctx.hookCommand("release", tool: agent.rawValue)),
            ],
            baseDocument: ["version": 1],
            installSummary: "wired sessionStart/sessionEnd hooks",
            uninstallSummary: "removed Cursor hook entries",
        )
    }

    /// MCP is gated off until device-verified, per the project rule that only agents whose MCP
    /// config format we've confirmed return a shape. Cursor *is believed* to read MCP servers from
    /// `~/.cursor/mcp.json` under `mcpServers` (same entry shape as Claude Code) — restore the shape
    /// below once that path + key are verified on a real install:
    ///
    /// ```
    /// MCPServerShape(configPath: "\(ctx.homeRoot)/.cursor/mcp.json",
    ///                serverName: HookContext.mcpServerName, entry: ctx.mcpEntry(tool: agent.rawValue))
    /// ```
    func mcpShape(_: HookContext) -> MCPServerShape? {
        nil
    }
}
