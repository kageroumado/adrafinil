import Foundation

/// Cursor: `~/.cursor/hooks.json`, `beforeSubmitPrompt` → acquire, `stop` → release (verified on
/// Cursor 3.12.17, issue #15). Cursor uses a flatter shape than Claude (`{"command": …}` entries
/// directly, no inner `hooks` wrapper) and a `version` field on a fresh file. No `CURSOR_SESSION_ID`
/// env var exists — Cursor passes `session_id` on the hook's stdin (for these events too).
///
/// Turn-scoped events, not `sessionStart`/`sessionEnd`: a Cursor session is a long-lived chat —
/// turns finish without ending it — so a session-scoped hold pinned the Mac awake long after the
/// agent stopped, and every open chat stacked another one. The usual backstops can't catch these:
/// each hold attaches to the single long-lived Cursor app process, so process-death cleanup never
/// fires, and the app's own UI activity keeps its tree from ever reading CPU-idle. That's also why
/// the acquire carries a TTL — with `stop` as the only release signal, the TTL is the last-resort
/// cap, refreshed on every prompt.
struct CursorIntegration: AgentIntegration {
    let agent = AgentKind.cursor

    /// Turns are minutes, not hours; anything still held after this long is stale (a missed `stop`).
    static let holdTTLSeconds = 3_600

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.cursor") ||
            FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.cursor/hooks.json"
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
                (event: "beforeSubmitPrompt", command: ctx.hookCommand("acquire", tool: agent.rawValue, ttlSeconds: Self.holdTTLSeconds)),
                (event: "stop", command: ctx.hookCommand("release", tool: agent.rawValue)),
            ],
            baseDocument: ["version": 1],
            installSummary: "wired beforeSubmitPrompt/stop hooks",
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
