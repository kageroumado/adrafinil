import Foundation
import Testing
@testable import AdrafinilShared

/// Covers the opt-in background-shell hook install path (`acquire --if-background`, a `PreToolUse`/Bash
/// hook), driven through the `HookInstaller` background API. It mirrors the MCP registration tests —
/// a separately-toggled capability, gated on `backgroundBashShape != nil` rather than `isDetected`, so
/// a bare temp home suffices for the shape itself. The core-hook coexistence tests additionally create
/// `~/.claude` so `install(for:)` runs, since the background hook shares Claude Code's `settings.json`
/// with the core acquire/release wiring.
@Suite("Background-shell hook")
struct BackgroundBashHookShapeTests {
    private func makeHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-bg-\(UUID().uuidString)")
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

    private func settingsPath(_ home: URL) -> String {
        home.path + "/.claude/settings.json"
    }

    /// Creates `~/.claude` so `isDetected` passes and `install(for:)` writes the core hooks.
    private func makeDetectedHome() throws -> URL {
        let home = try makeHome()
        try FileManager.default.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        return home
    }

    /// The single Adrafinil handler under `PreToolUse`, or nil. Walks the nested group/handler shape.
    private func backgroundCommand(in home: URL) throws -> String? {
        let hooks = try #require(try readJSON(settingsPath(home))["hooks"] as? [String: Any])
        guard let groups = hooks["PreToolUse"] as? [[String: Any]] else { return nil }
        for group in groups {
            if let inner = group["hooks"] as? [[String: Any]],
               let ours = inner.first(where: { ($0["_adrafinil"] as? Bool) == true }) {
                return ours["command"] as? String
            }
        }
        return nil
    }

    // MARK: - Capability gating

    @Test
    func `supports background hold only for Claude Code`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        #expect(inst.supportsBackgroundHold(for: .claudeCode))
        for agent in [AgentKind.codex, .cursor, .geminiCLI, .aider, .cline, .hermes, .openCode, .pi] {
            #expect(!inst.supportsBackgroundHold(for: agent), "\(agent.rawValue) has no clean run_in_background signal")
        }
    }

    @Test
    func `install throws for an unsupported agent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer(home).installBackgroundHold(for: .codex)
        }
    }

    // MARK: - Install

    @Test
    func `install writes a PreToolUse Bash acquire --if-background hook`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try installer(home).installBackgroundHold(for: .claudeCode)

        let hooks = try #require(try readJSON(settingsPath(home))["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let group = try #require(groups.first)
        #expect(group["matcher"] as? String == "Bash", "the hook must be narrowed to the Bash tool")
        let command = try #require(try backgroundCommand(in: home))
        #expect(command == "/usr/local/bin/adrafinil acquire --tool claude-code --if-background --ttl \(Int(BackgroundBashHold.defaultTTLSeconds))")
    }

    @Test
    func `install preserves the user's other PreToolUse hooks`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Seed a user's own PreToolUse hook (a different matcher) plus unrelated top-level state.
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Write", "hooks": [["type": "command", "command": "my-linter"]]]]],
        ]
        try FileManager.default.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: settingsPath(home)))

        _ = try installer(home).installBackgroundHold(for: .claudeCode)

        let dict = try readJSON(settingsPath(home))
        #expect(dict["model"] as? String == "opus", "unrelated top-level keys must survive")
        let groups = try #require((dict["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(groups.contains { ($0["matcher"] as? String) == "Write" }, "the user's own PreToolUse hook must survive")
        #expect(try backgroundCommand(in: home) != nil, "ours is added alongside")
    }

    @Test
    func `install is idempotent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        _ = try inst.installBackgroundHold(for: .claudeCode)
        _ = try inst.installBackgroundHold(for: .claudeCode)

        let groups = try #require(try (readJSON(settingsPath(home))["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        let ourGroups = groups.filter { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["_adrafinil"] as? Bool) == true } ?? false
        }
        #expect(ourGroups.count == 1, "re-install must not duplicate our group")
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed)
    }

    @Test
    func `dry run does not touch disk`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try installer(home).installBackgroundHold(for: .claudeCode, dryRun: true)
        #expect(!result.diff.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: settingsPath(home)))
    }

    // MARK: - Uninstall & state

    @Test
    func `uninstall removes only our hook`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let existing: [String: Any] = [
            "hooks": ["PreToolUse": [["matcher": "Write", "hooks": [["type": "command", "command": "my-linter"]]]]],
        ]
        try FileManager.default.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: settingsPath(home)))

        let inst = installer(home)
        _ = try inst.installBackgroundHold(for: .claudeCode)
        _ = try inst.uninstallBackgroundHold(for: .claudeCode)

        #expect(try backgroundCommand(in: home) == nil, "our hook must be gone")
        let groups = try #require(try (readJSON(settingsPath(home))["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(groups.contains { ($0["matcher"] as? String) == "Write" }, "the user's own hook must remain")
    }

    @Test
    func `uninstall is a no-op when absent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try installer(home).uninstallBackgroundHold(for: .claudeCode)
        #expect(result.diff == "(unchanged)")
    }

    @Test
    func `state transitions and toggle on-off-on is consistent`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .notInstalled)
        _ = try inst.installBackgroundHold(for: .claudeCode)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed)
        _ = try inst.uninstallBackgroundHold(for: .claudeCode)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .notInstalled)
        _ = try inst.installBackgroundHold(for: .claudeCode)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed, "re-enabling must restore cleanly")
    }

    @Test
    func `state is modified when the embedded TTL drifts`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)
        _ = try inst.installBackgroundHold(for: .claudeCode)

        // Hand-edit the command (e.g. an older build's TTL). The state must flag it for a reconnect,
        // and a reinstall must repair it in place.
        var dict = try readJSON(settingsPath(home))
        dict["hooks"] = ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/adrafinil acquire --tool claude-code --if-background --ttl 999", "_adrafinil": true]]]]]
        try JSONSerialization.data(withJSONObject: dict).write(to: URL(fileURLWithPath: settingsPath(home)))
        #expect(inst.backgroundHoldState(for: .claudeCode) == .modifiedExternally)

        _ = try inst.installBackgroundHold(for: .claudeCode)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed)
    }

    // MARK: - Coexistence with the Part-1 core hooks

    @Test
    func `the background hook coexists with the core hooks without disturbing them`() throws {
        let home = try makeDetectedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)

        _ = try inst.install(for: .claudeCode, dryRun: false)
        #expect(inst.installState(for: .claudeCode) == .installed)
        _ = try inst.installBackgroundHold(for: .claudeCode)

        // Both live in the same settings.json; each reads as installed, and neither perturbs the other.
        #expect(inst.installState(for: .claudeCode) == .installed, "core hooks stay connected")
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed)

        // Removing the background hook leaves the core per-turn/sub-agent hooks intact.
        _ = try inst.uninstallBackgroundHold(for: .claudeCode)
        #expect(inst.installState(for: .claudeCode) == .installed, "core hooks survive a background toggle-off")
        #expect(inst.backgroundHoldState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `the core uninstall strips the background hook — the desync the app re-applies`() throws {
        let home = try makeDetectedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let inst = installer(home)

        _ = try inst.install(for: .claudeCode, dryRun: false)
        _ = try inst.installBackgroundHold(for: .claudeCode)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .installed)

        // Disconnecting the agent (core uninstall) strips *every* Adrafinil handler — including this
        // one. This is exactly why the app re-applies the background hook on reconnect when the
        // setting is on (see LiveAgentHooksProvider.install).
        _ = try inst.uninstall(for: .claudeCode)
        #expect(inst.installState(for: .claudeCode) == .notInstalled)
        #expect(inst.backgroundHoldState(for: .claudeCode) == .notInstalled, "core uninstall takes the background hook with it")
    }
}
