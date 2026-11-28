import Foundation

/// Antigravity (Antigravity CLI `agy`, App, and IDE): `~/.gemini/config/hooks.json`,
/// `PreInvocation` → acquire, `Stop` → release (verified against Antigravity CLI 1.5.14).
///
/// Antigravity's `hooks.json` maps top-level **hook names** to their event definitions, with flat
/// handler arrays for lifecycle events (no `hooks` wrapper or `matcher`, unlike `PreToolUse`/
/// `PostToolUse`):
///
/// ```json
/// {
///   "adrafinil": {
///     "PreInvocation": [ { "type": "command", "command": "…/adrafinil acquire --tool antigravity" } ],
///     "Stop":          [ { "type": "command", "command": "…/adrafinil release --tool antigravity" } ]
///   }
/// }
/// ```
///
/// Because `"adrafinil"` is a dedicated top-level named hook, the key itself is the idempotency
/// handle (paralleling `MCPServerShape`) — install upserts only `"adrafinil"` and uninstall removes
/// only that key, leaving sibling named hooks untouched.
///
/// **Activity-scoped, not session-scoped** (like Claude Code, Codex, Cursor, and Devin):
/// `PreInvocation` fires before each model call (idempotent re-acquire refreshes `lastActivityAt`),
/// and `Stop` fires once the execution loop finishes — including after background tool commands
/// complete in `-p` mode (verified). There is no `UserPromptSubmit` or `SessionEnd` event. Every
/// hook payload uses protojson camelCase and carries `conversationId` on stdin (read by
/// `HookPayload.sessionID(in:)`), so the commands pass no positional session key. Empty stdout
/// with exit 0 is accepted cleanly on both `PreInvocation` and `Stop`.
///
/// No TTL: the hook's parent process is the `antigravity` binary (`agy` execs it directly), so the
/// daemon's process-exit watcher covers a terminated turn (SIGINT fires no `Stop`; verified) and
/// the CPU-idle sweep covers an interrupted interactive turn (an idle CLI sits at ~0% CPU).
///
/// Antigravity App, CLI, and IDE all share `~/.gemini/config/hooks.json` and
/// `~/.gemini/config/mcp_config.json`, so one integration covers all three surfaces (mirroring
/// Devin). Detection checks their per-surface data directories under `~/.gemini/` plus
/// `/Applications/Antigravity.app`.
///
/// **MCP.** `~/.gemini/config/mcp_config.json` under `mcpServers` — verified against Antigravity
/// CLI 1.5.14, which pre-creates a 0-byte `mcp_config.json` on first run and loads `keep_awake`,
/// `release_awake`, and `awake_status` once registered.
struct AntigravityIntegration: AgentIntegration {
    let agent = AgentKind.antigravity

    /// Top-level named hook key in `~/.gemini/config/hooks.json`.
    static let hookName = "adrafinil"

    func isDetected(_ ctx: HookContext) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "\(ctx.homeRoot)/.gemini/antigravity-cli")
            || fm.fileExists(atPath: "\(ctx.homeRoot)/.gemini/antigravity")
            || fm.fileExists(atPath: "\(ctx.homeRoot)/.gemini/antigravity-ide")
            || fm.fileExists(atPath: "/Applications/Antigravity.app")
    }

    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.gemini/config/hooks.json"
    }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let path = primaryConfigPath(ctx)
        let existing = try ConfigFileIO.readJSONForUpdate(path)
        let before = existing ?? [:]
        var after = before
        after[Self.hookName] = canonicalEntry(ctx)

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: path)
            try ConfigFileIO.writeJSON(after, to: path, replacing: existing)
        }
        return HookInstaller.InstallResult(
            summary: "wired PreInvocation acquire + Stop release hooks",
            diff: diff,
        )
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let path = primaryConfigPath(ctx)
        guard let existing = try ConfigFileIO.readJSONForUpdate(path),
              existing[Self.hookName] != nil else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        dict.removeValue(forKey: Self.hookName)

        let diff = ConfigFileIO.makeDiff(before: existing, after: dict)
        if !dryRun {
            try ConfigFileIO.writeJSON(dict, to: path, replacing: existing)
        }
        return HookInstaller.InstallResult(summary: "removed Antigravity hook entries", diff: diff)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        switch ConfigFileIO.read(primaryConfigPath(ctx)) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            guard let raw = dict[Self.hookName] else { return .notInstalled }
            guard let installed = raw as? [String: Any] else { return .modifiedExternally }
            return NSDictionary(dictionary: installed).isEqual(to: canonicalEntry(ctx))
                ? .installed
                : .modifiedExternally
        }
    }

    /// MCP lives in `~/.gemini/config/mcp_config.json` under `mcpServers` — verified against
    /// Antigravity CLI 1.5.14, which loads it and exposes `keep_awake`/`release_awake`/`awake_status`.
    func mcpShape(_ ctx: HookContext) -> MCPServerShape? {
        MCPServerShape(
            configPath: "\(ctx.homeRoot)/.gemini/config/mcp_config.json",
            serverName: HookContext.mcpServerName,
            entry: ctx.mcpEntry(tool: agent.rawValue),
        )
    }

    private func canonicalEntry(_ ctx: HookContext) -> [String: Any] {
        [
            "PreInvocation": [
                ["type": "command", "command": ctx.hookCommand("acquire", tool: agent.rawValue)],
            ],
            "Stop": [
                ["type": "command", "command": ctx.hookCommand("release", tool: agent.rawValue)],
            ],
        ]
    }
}
