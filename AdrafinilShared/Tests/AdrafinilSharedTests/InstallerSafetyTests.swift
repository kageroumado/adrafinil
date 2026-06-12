import Foundation
import Testing
@testable import AdrafinilShared

/// Safety properties of the hook installers: configs owned by other programs must never be
/// destroyed (unparseable files, symlinked dotfiles, damaged marker blocks), and only entries
/// that are provably ours may be rewritten or removed.
@Suite("Installer safety")
struct InstallerSafetyTests {
    private func makeFakeHome(detectedDirs: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in detectedDirs {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }

    private func readJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - Unparseable configs are never overwritten

    @Test
    func `install refuses a config with comments and leaves it untouched`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"
        let jsonc = """
        {
          // my permission allowlist — do not lose this
          "permissions": {"allow": ["Bash(npm:*)"]}
        }
        """
        try jsonc.write(toFile: path, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer.install(for: .claudeCode, dryRun: false)
        }
        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(after == jsonc, "an unparseable config must be left byte-identical")
        #expect(installer.installState(for: .claudeCode) == .configUnreadable)
    }

    @Test
    func `uninstall refuses an unparseable config rather than reporting nothing to remove`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            try installer.uninstall(for: .claudeCode)
        }
    }

    @Test
    func `install refuses an array-rooted config`() throws {
        let home = try makeFakeHome(detectedDirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.cursor/hooks.json"
        try "[1, 2, 3]".write(toFile: path, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer.install(for: .cursor, dryRun: false)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[1, 2, 3]")
    }

    @Test
    func `mcp install refuses an unparseable claude json`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        // ~/.claude.json holds Claude Code's whole state — the worst file to wipe.
        let path = home.path + "/.claude.json"
        try "{ \"oauthAccount\": ".write(toFile: path, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            try installer.installMCP(for: .claudeCode)
        }
        #expect(installer.mcpState(for: .claudeCode) == .configUnreadable)
    }

    @Test
    func `write refuses when the config changed between read and write`() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/config.json"
        try #"{"a": 1}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let stale = ["a": 2] as [String: Any]
        #expect(throws: HookInstaller.SkipReason.self) {
            try ConfigFileIO.writeJSON(["a": 3], to: path, replacing: stale)
        }
        #expect(try readJSON(path)["a"] as? Int == 1, "a conflicting write must not land")
    }

    // MARK: - Symlinked configs (stow/chezmoi) survive writes

    @Test
    func `install through a symlinked config keeps the symlink and its permissions`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude", "dotfiles"])
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.path + "/dotfiles/claude-settings.json"
        let link = home.path + "/.claude/settings.json"
        try #"{"permissions": {"allow": []}}"#.write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let attrs = try FileManager.default.attributesOfItem(atPath: link)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink, "the symlink must survive the write")
        let targetDict = try readJSON(target)
        #expect(targetDict["hooks"] != nil, "the write must land in the symlink's target")
        #expect(targetDict["permissions"] != nil, "user content must survive")
        let targetPerms = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        #expect(targetPerms == 0o600, "original permissions must be preserved")
    }

    // MARK: - ShellWrapper never truncates rc files

    @Test
    func `uninstall with a deleted end marker preserves everything after the block`() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let zshrc = home.path + "/.zshrc"
        let userTail = "export PATH=$HOME/bin:$PATH\nsource ~/.fzf.zsh\nalias gs='git status'"
        try """
        # my prelude
        # adrafinil-aider
        alias aider='\(home.path)/.local/bin/aider-adrafinil'
        \(userTail)
        """.write(toFile: zshrc, atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().uninstall(ctx, dryRun: false)

        let after = try String(contentsOfFile: zshrc, encoding: .utf8)
        #expect(after.contains(userTail), "user content after a damaged block must survive")
        #expect(after.contains("# my prelude"))
        #expect(!after.contains("adrafinil"), "our lines must be gone")
    }

    @Test
    func `install repairs a wrapper script whose cli path drifted`() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().install(ctx, dryRun: false)

        // The app moved: a fresh context with the new path must see drift and repair it.
        let movedCtx = HookContext(cliPath: "/Applications/Adrafinil.app/Contents/Helpers/adrafinil", homeRoot: home.path)
        #expect(AiderIntegration().installState(movedCtx) == .modifiedExternally)
        _ = try AiderIntegration().install(movedCtx, dryRun: false)
        #expect(AiderIntegration().installState(movedCtx) == .installed)
        let script = try String(contentsOfFile: home.path + "/.local/bin/aider-adrafinil", encoding: .utf8)
        #expect(script.contains("/Applications/Adrafinil.app"))
        #expect(!script.contains("/usr/local/bin/adrafinil "))
    }

    @Test
    func `install touches only rc files that exist`() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().install(ctx, dryRun: false)

        #expect(!FileManager.default.fileExists(atPath: home.path + "/.bashrc"), "a missing rc file must not be created")
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .aider) == .installed, "one rc file with the alias is a complete install")
    }

    // MARK: - Hermes line-scoped YAML surgery

    @Test
    func `hermes install never rewrites a nested or lookalike hooks map`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = home.path + "/.hermes/config.yaml"
        // No top-level hooks map; a nested empty one and a lookalike key that must both survive.
        try "agents:\n  sub:\n    hooks: {}\npython_hooks: {}\n"
            .write(toFile: cfg, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .hermes, dryRun: false)

        let after = try String(contentsOfFile: cfg, encoding: .utf8)
        #expect(after.contains("    hooks: {}"), "the nested empty hooks map must survive verbatim")
        #expect(after.contains("python_hooks: {}"), "a lookalike key must survive verbatim")
        #expect(after.contains("on_session_start"), "our block must be appended as a new top-level hooks map")
    }

    @Test
    func `hermes install repairs a stale cli path in place`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = home.path + "/.hermes/config.yaml"
        try "model:\n  default: x\nhooks: {}\n".write(toFile: cfg, atomically: true, encoding: .utf8)

        let oldInstaller = HookInstaller(cliPath: "/old/place/adrafinil", homeRoot: home.path)
        _ = try oldInstaller.install(for: .hermes, dryRun: false)

        let newInstaller = HookInstaller(cliPath: "/Applications/Adrafinil.app/Contents/Helpers/adrafinil", homeRoot: home.path)
        #expect(newInstaller.installState(for: .hermes) == .modifiedExternally, "a dead CLI path must not read as notInstalled or installed")

        _ = try newInstaller.install(for: .hermes, dryRun: false)
        #expect(newInstaller.installState(for: .hermes) == .installed)
        let after = try String(contentsOfFile: cfg, encoding: .utf8)
        #expect(!after.contains("/old/place/adrafinil"), "the stale block must be gone")
        #expect(after.components(separatedBy: "on_session_start").count == 2, "exactly one acquire hook")

        // The allowlist must hold approvals only for the current commands.
        let allow = try readJSON(home.path + "/.hermes/shell-hooks-allowlist.json")
        let approvals = try #require(allow["approvals"] as? [[String: Any]])
        #expect(approvals.count == 3)
        #expect(approvals.allSatisfy { ($0["command"] as? String)?.contains("/old/place") != true })
    }

    @Test
    func `hermes allowlist round-trips foreign keys and user approvals`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        try "hooks: {}\n".write(toFile: home.path + "/.hermes/config.yaml", atomically: true, encoding: .utf8)
        let allowPath = home.path + "/.hermes/shell-hooks-allowlist.json"
        let seeded: [String: Any] = [
            "version": 2,
            "approvals": [["event": "on_session_end", "command": "/usr/bin/say done"]],
        ]
        try JSONSerialization.data(withJSONObject: seeded).write(to: URL(fileURLWithPath: allowPath))

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .hermes, dryRun: false)
        try installer.uninstall(for: .hermes)

        let after = try readJSON(allowPath)
        #expect(after["version"] as? Int == 2, "foreign top-level keys must survive install + uninstall")
        let approvals = try #require(after["approvals"] as? [[String: Any]])
        #expect(approvals.contains { ($0["command"] as? String) == "/usr/bin/say done" }, "user approvals must survive")
        #expect(approvals.allSatisfy { ($0["command"] as? String)?.contains("adrafinil") != true })
    }

    // MARK: - Ownership: only provably-ours entries are rewritten or removed

    @Test
    func `a user hook merely containing the word adrafinil is never ours`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"
        let userCommand = "~/bin/adrafinil-notify.sh"
        let seeded: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": userCommand]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seeded).write(to: URL(fileURLWithPath: path))

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        var hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        var start = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(start.count == 2, "the user's hook must be preserved alongside ours")

        try installer.uninstall(for: .claudeCode)
        hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        start = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(start.count == 1)
        let survivor = ((start[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(survivor == userCommand, "uninstall must remove only our entry")
    }

    @Test
    func `repair and uninstall preserve a user handler sharing our group`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // The user adds their own handler inside OUR group's inner hooks array.
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        var start = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        var inner = try #require(start[0]["hooks"] as? [[String: Any]])
        inner.append(["type": "command", "command": "echo sibling"])
        start[0]["hooks"] = inner
        hooks["UserPromptSubmit"] = start
        dict["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: dict).write(to: URL(fileURLWithPath: path))

        // Reinstall (repair) must not clobber the sibling.
        _ = try installer.install(for: .claudeCode, dryRun: false)
        var innerAfter = try #require(try ((readJSON(path)["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(innerAfter.contains { ($0["command"] as? String) == "echo sibling" }, "repair must replace only our handler")

        // Uninstall must remove only our handler, keeping the group for the sibling.
        try installer.uninstall(for: .claudeCode)
        innerAfter = try #require(try ((readJSON(path)["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(innerAfter.count == 1)
        #expect((innerAfter.first?["command"] as? String) == "echo sibling")
    }

    @Test
    func `leftover release hooks after a deleted acquire read as drift not notInstalled`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // Delete only the acquire entry; our Stop + Notification releases remain live.
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        hooks["UserPromptSubmit"] = nil
        dict["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: dict).write(to: URL(fileURLWithPath: path))

        #expect(
            installer.installState(for: .claudeCode) == .modifiedExternally,
            "live adrafinil entries must never be invisible as notInstalled",
        )
    }

    @Test
    func `cursor uninstall leaves no empty event arrays behind`() throws {
        let home = try makeFakeHome(detectedDirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .cursor, dryRun: false)
        try installer.uninstall(for: .cursor)

        let dict = try readJSON(home.path + "/.cursor/hooks.json")
        let hooks = (dict["hooks"] as? [String: Any]) ?? [:]
        #expect(hooks["sessionStart"] == nil, "emptied event keys must be dropped")
        #expect(hooks["sessionEnd"] == nil)
    }

    // MARK: - Generated-code escaping

    @Test
    func `shell quoting survives quotes and metacharacters in the cli path`() {
        let plain = HookContext(cliPath: "/Applications/Adrafinil.app/Contents/Helpers/adrafinil", homeRoot: "/tmp")
        #expect(plain.quotedCLI == plain.cliPath, "a plain path needs no quoting")

        let spaced = HookContext(cliPath: "/Apps/My Tools/adrafinil", homeRoot: "/tmp")
        #expect(spaced.quotedCLI == "'/Apps/My Tools/adrafinil'")

        let quoted = HookContext(cliPath: "/Apps/it's here/adrafinil", homeRoot: "/tmp")
        #expect(quoted.quotedCLI == "'/Apps/it'\\''s here/adrafinil'")
    }

    @Test
    func `pi extension escapes quotes in the cli path`() throws {
        let home = try makeFakeHome(detectedDirs: [".pi"])
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = HookContext(cliPath: "/Apps/say \"hi\"/adrafinil", homeRoot: home.path)
        _ = try PiIntegration().install(ctx, dryRun: false)

        let ts = try String(contentsOfFile: home.path + "/.pi/agent/extensions/adrafinil.ts", encoding: .utf8)
        #expect(ts.contains(#"\"hi\""#), "quotes in the path must be escaped in the generated literal")
        #expect(!ts.contains(#"execFileSync("/Apps/say "hi""#), "an unescaped quote would break the literal")
    }
}
