import Foundation

/// Registers (or removes) Adrafinil's MCP server inside an agent's JSON config — the agent-facing
/// side of `adrafinil mcp`, exposing `keep_awake` / `release_awake` / `awake_status` so the agent
/// can hold sleep on its own.
///
/// Parallels the hook shapes but is simpler: an MCP server is a single *named* entry under a
/// container object (`mcpServers` for Claude Code / Cursor / Gemini CLI), so the server name is its
/// own idempotency handle — no `_adrafinil` tag is needed. Install upserts our entry, uninstall
/// removes just that key, and the user's other servers are always preserved.
///
/// ```json
/// { "mcpServers": { "adrafinil": { "type": "stdio", "command": "…/adrafinil", "args": ["mcp", "--tool", "claude-code"] } } }
/// ```
struct MCPServerShape {
    let configPath: String
    /// Top-level container holding named servers. `mcpServers` for the verified agents.
    var containerKey: String = "mcpServers"
    /// The name Adrafinil registers under (and the key it removes on uninstall).
    let serverName: String
    /// The canonical server entry (`{type, command, args}`), also the yardstick for `installState`.
    let entry: [String: Any]

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var servers = (after[containerKey] as? [String: Any]) ?? [:]
        servers[serverName] = entry
        after[containerKey] = servers

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        return HookInstaller.InstallResult(summary: "registered \(serverName) MCP server", diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var servers = existing[containerKey] as? [String: Any],
              servers[serverName] != nil else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        servers.removeValue(forKey: serverName)
        // Leave an emptied container in place rather than deleting it — non-destructive, and the
        // agent treats an empty `mcpServers` the same as none.
        dict[containerKey] = servers
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed \(serverName) MCP server", diff: diff)
    }

    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            guard let servers = dict[containerKey] as? [String: Any],
                  let installed = servers[serverName] as? [String: Any] else { return .notInstalled }
            // Deep-compare the on-disk entry to what we'd write; nested arrays (`args`) are handled by
            // NSDictionary's structural equality.
            return NSDictionary(dictionary: installed).isEqual(to: entry) ? .installed : .modifiedExternally
        }
    }
}
