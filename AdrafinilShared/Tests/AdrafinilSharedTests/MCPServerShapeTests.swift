import Foundation
import Testing
@testable import AdrafinilShared

/// Covers the agent-facing MCP server registration (`adrafinil mcp`) — the upsert/remove/state
/// machinery, driven through the `HookInstaller` MCP API. Claude Code is the only device-verified
/// MCP agent (Cursor/Gemini are gated off until verified). MCP registration is gated on
/// `mcpShape != nil`, not `isDetected`, so a bare temp home suffices.
@Suite("MCP server registration")
struct MCPServerShapeTests {
    private func makeHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func readJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func installer(_ home: URL) -> HookInstaller {
        HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
    }

    private func claudeConfig(_ home: URL) -> String {
        home.path + "/.claude.json"
    }

    // MARK: - Capability gating

    @Test
    func `supports MCP only for verified agents`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        // Only Claude Code's MCP format is device-verified, so it's the only agent that advertises
        // MCP support. Cursor and Gemini are believed-correct but gated off until verified.
        #expect(inst.supportsMCP(for: .claudeCode))
        for agent in [AgentKind.codex, .cursor, .geminiCLI, .aider, .cline, .hermes, .openCode, .pi] {
            #expect(!inst.supportsMCP(for: agent), "\(agent.rawValue) should be gated until device-verified")
        }
    }

    @Test
    func `install MCP throws for unsupported agent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer(home).installMCP(for: .codex)
        }
    }

    // MARK: - Install

    @Test
    func `install registers stdio server with tool flag`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try installer(home).installMCP(for: .claudeCode)

        let dict = try readJSON(claudeConfig(home))
        let servers = try #require(dict["mcpServers"] as? [String: Any])
        let entry = try #require(servers["adrafinil"] as? [String: Any])
        #expect(entry["type"] as? String == "stdio")
        #expect(entry["command"] as? String == "/usr/local/bin/adrafinil")
        let args = try #require(entry["args"] as? [String])
        #expect(args == ["mcp", "--tool", "claude-code"])
    }

    @Test
    func `install preserves existing servers`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Seed a realistic ~/.claude.json with a user MCP server and unrelated top-level state.
        let existing: [String: Any] = [
            "anonymousId": "abc-123",
            "mcpServers": ["voicemode": ["type": "stdio", "command": "uvx", "args": ["voice-mode"]]],
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: URL(fileURLWithPath: claudeConfig(home)))

        _ = try installer(home).installMCP(for: .claudeCode)

        let dict = try readJSON(claudeConfig(home))
        #expect(dict["anonymousId"] as? String == "abc-123", "unrelated top-level keys must survive")
        let servers = try #require(dict["mcpServers"] as? [String: Any])
        #expect(servers["voicemode"] != nil, "the user's other MCP servers must survive")
        #expect(servers["adrafinil"] != nil)
    }

    @Test
    func `install is idempotent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        _ = try inst.installMCP(for: .claudeCode)
        _ = try inst.installMCP(for: .claudeCode)

        let servers = try #require(try readJSON(claudeConfig(home))["mcpServers"] as? [String: Any])
        #expect(servers.keys.count(where: { $0 == "adrafinil" }) == 1)
        #expect(inst.mcpState(for: .claudeCode) == .installed)
    }

    @Test
    func `dry run does not touch disk`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try installer(home).installMCP(for: .claudeCode, dryRun: true)
        #expect(!result.diff.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: claudeConfig(home)))
    }

    @Test
    func `gated agents refuse MCP install and write nothing`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        // Cursor and Gemini MCP formats aren't device-verified yet, so installMCP must refuse — and
        // crucially must not write a (possibly malformed) config to the user's agent.
        for agent in [AgentKind.cursor, .geminiCLI] {
            #expect(throws: HookInstaller.SkipReason.self) {
                _ = try inst.installMCP(for: agent)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.cursor/mcp.json"))
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.gemini/settings.json"))
    }

    // MARK: - Uninstall

    @Test
    func `uninstall removes only our server`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let existing: [String: Any] = [
            "mcpServers": ["voicemode": ["type": "stdio", "command": "uvx", "args": ["voice-mode"]]],
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: URL(fileURLWithPath: claudeConfig(home)))

        let inst = installer(home)
        _ = try inst.installMCP(for: .claudeCode)
        _ = try inst.uninstallMCP(for: .claudeCode)

        let servers = try #require(try readJSON(claudeConfig(home))["mcpServers"] as? [String: Any])
        #expect(servers["adrafinil"] == nil, "our server must be gone")
        #expect(servers["voicemode"] != nil, "the user's server must remain")
    }

    @Test
    func `uninstall is no op when absent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try installer(home).uninstallMCP(for: .claudeCode)
        #expect(result.diff == "(unchanged)")
    }

    // MARK: - State

    @Test
    func `state transitions`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        #expect(inst.mcpState(for: .claudeCode) == .notInstalled)
        _ = try inst.installMCP(for: .claudeCode)
        #expect(inst.mcpState(for: .claudeCode) == .installed)
        _ = try inst.uninstallMCP(for: .claudeCode)
        #expect(inst.mcpState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `state is modified when entry tampered`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        _ = try inst.installMCP(for: .claudeCode)

        var dict = try readJSON(claudeConfig(home))
        var servers = try #require(dict["mcpServers"] as? [String: Any])
        servers["adrafinil"] = ["type": "stdio", "command": "/somewhere/else/adrafinil", "args": ["mcp"]]
        dict["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: dict)
            .write(to: URL(fileURLWithPath: claudeConfig(home)))

        #expect(inst.mcpState(for: .claudeCode) == .modifiedExternally)
    }
}
