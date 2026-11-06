import Foundation
import Testing
@testable import AdrafinilShared

/// Issue #37: a Claude Code profile run with `CLAUDE_CONFIG_DIR` reads its settings (and its
/// `.claude.json`) from that directory, so `install-hooks --config-dir` writes there instead.
extension HookInstallerTests {
    private func profileInstaller(_ home: URL, dir: String = ".claude-work") -> HookInstaller {
        HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path, claudeConfigDir: home.path + "/" + dir)
    }

    @Test
    func `custom config dir gets the hooks and the default profile is untouched`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude", ".claude-work"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = profileInstaller(home)
        #expect(installer.configPath(for: .claudeCode) == home.path + "/.claude-work/settings.json")
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let hooks = try #require(try readJSON(home.path + "/.claude-work/settings.json")["hooks"] as? [String: Any])
        let submit = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        let inner = try #require(submit.first?["hooks"] as? [[String: Any]])
        // Same command as the default profile: holds from every profile are plain Claude Code holds.
        #expect((inner.first?["command"] as? String)?.contains("--tool claude-code") == true)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.claude/settings.json"))

        #expect(installer.installState(for: .claudeCode) == .installed)
        let defaultInstaller = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(defaultInstaller.installState(for: .claudeCode) == .notInstalled)

        _ = try installer.uninstall(for: .claudeCode)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `custom config dir that does not exist is not detected`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: HookInstaller.SkipReason.self) {
            try profileInstaller(home).install(for: .claudeCode, dryRun: false)
        }
    }

    /// With `CLAUDE_CONFIG_DIR` set, Claude Code keeps its global state file — and so user-scope
    /// `mcpServers` — inside the directory, not at `~/.claude.json`.
    @Test
    func `custom config dir registers MCP inside the dir`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude-work"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = profileInstaller(home)
        _ = try installer.installMCP(for: .claudeCode)

        let servers = try #require(try readJSON(home.path + "/.claude-work/.claude.json")["mcpServers"] as? [String: Any])
        #expect(servers["adrafinil"] != nil)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.claude.json"))
        #expect(installer.mcpState(for: .claudeCode) == .installed)

        _ = try installer.uninstallMCP(for: .claudeCode)
        #expect(installer.mcpState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `custom config dir gets the background shell hook`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude-work"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = profileInstaller(home)
        _ = try installer.installBackgroundHold(for: .claudeCode)

        let hooks = try #require(try readJSON(home.path + "/.claude-work/settings.json")["hooks"] as? [String: Any])
        #expect(hooks["PreToolUse"] != nil)
        #expect(installer.backgroundHoldState(for: .claudeCode) == .installed)
    }

    @Test
    func `other agents ignore the claude config dir`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini", ".claude-work"])
        defer { try? FileManager.default.removeItem(at: home) }

        _ = try profileInstaller(home).install(for: .geminiCLI, dryRun: false)
        #expect(FileManager.default.fileExists(atPath: home.path + "/.gemini/settings.json"))
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.claude-work/settings.json"))
    }

    // MARK: - Path normalization

    @Test
    func `normalizes config dir paths`() {
        let home = "/Users/me"
        func norm(_ raw: String?) -> String? {
            HookInstaller.normalizedClaudeConfigDir(raw, homeRoot: home, currentDirectory: "/Users/me/src")
        }
        #expect(norm("~/.claude-work") == "/Users/me/.claude-work")
        #expect(norm("/Users/me/.claude-work/") == "/Users/me/.claude-work")
        #expect(norm("/Users/me/x/../.claude-work") == "/Users/me/.claude-work")
        #expect(norm("../.claude-work") == "/Users/me/.claude-work")
        #expect(norm("  /Users/me/.claude-work  ") == "/Users/me/.claude-work")
        // The default profile always takes the default code path.
        #expect(norm("~/.claude") == nil)
        #expect(norm("/Users/me/.claude/") == nil)
        #expect(norm("") == nil)
        #expect(norm(nil) == nil)
    }
}
