import Testing
import Foundation
@testable import AdrafinilShared

@Suite("HookInstaller")
struct HookInstallerTests {

    /// Creates a tempdir-rooted fake home with the given subdirs pre-created so
    /// `isDetected()` returns true for the target agents.
    private func makeFakeHome(detectedDirs: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-test-\(UUID().uuidString)")
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

    // MARK: - Detection

    @Test func detectsClaudeCodeByConfigDir() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let detected = HookInstaller.detectedAgents(homeRoot: home.path)
        #expect(detected.contains(.claudeCode))
        #expect(!detected.contains(.codex))
    }

    @Test func detectsAllTier1WhenAllPresent() throws {
        let home = try makeFakeHome(detectedDirs: [".claude", ".codex", ".cursor", ".gemini"])
        defer { try? FileManager.default.removeItem(at: home) }
        let detected = Set(HookInstaller.detectedAgents(homeRoot: home.path))
        #expect(detected.isSuperset(of: [.claudeCode, .codex, .cursor, .geminiCLI]))
    }

    // MARK: - Install: Claude Code shape

    @Test func installClaudeCodeWritesSessionStartAndEnd() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try installer.install(for: .claudeCode, dryRun: false)

        #expect(result.summary.contains("SessionStart"))
        #expect(result.summary.contains("SessionEnd"))

        let path = home.path + "/.claude/settings.json"
        let dict = try readJSON(path)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)
    }

    @Test func installCodexUsesStopInsteadOfSessionEnd() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)

        let dict = try readJSON(home.path + "/.codex/hooks.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["Stop"] != nil, "Codex has no SessionEnd — must use Stop")
        #expect(hooks["SessionEnd"] == nil)
    }

    @Test func installIsIdempotent() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let dict = try readJSON(home.path + "/.claude/settings.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["SessionStart"] as? [Any])
        #expect(startEntries.count == 1, "double-install should not duplicate hook entries")
    }

    @Test func installPreservesExistingUserHooks() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        // User already has a hook configured.
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "echo user-hook"]]]
                ]
            ]
        ]
        let settingsPath = home.path + "/.claude/settings.json"
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try existingData.write(to: URL(fileURLWithPath: settingsPath))

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let dict = try readJSON(settingsPath)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["SessionStart"] as? [Any])
        #expect(startEntries.count == 2, "must preserve the user's existing hook alongside ours")
    }

    @Test func dryRunDoesNotTouchDisk() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try installer.install(for: .claudeCode, dryRun: true)

        #expect(!result.diff.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.claude/settings.json"))
    }

    @Test func installSkipsUndetectedAgent() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer.install(for: .claudeCode, dryRun: false)
        }
    }

    // MARK: - Uninstall

    @Test func uninstallRemovesOnlyAdrafinilEntries() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        // Seed a user hook first.
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "echo user-hook"]]]]
            ]
        ]
        let settingsPath = home.path + "/.claude/settings.json"
        let data = try JSONSerialization.data(withJSONObject: existing, options: [])
        try data.write(to: URL(fileURLWithPath: settingsPath))

        _ = try installer.install(for: .claudeCode, dryRun: false)
        try installer.uninstall(for: .claudeCode)

        let dict = try readJSON(settingsPath)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["SessionStart"] as? [Any])
        #expect(startEntries.count == 1, "uninstall must leave the user's hook intact")
    }

    @Test func uninstallDryRunDoesNotTouchDisk() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let settingsPath = home.path + "/.claude/settings.json"
        let beforeData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let result = try installer.uninstall(for: .claudeCode, dryRun: true)

        #expect(!result.diff.isEmpty)
        #expect(result.diff != "(unchanged)")
        let afterData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        #expect(beforeData == afterData, "dry-run uninstall must not modify files on disk")
    }

    // MARK: - installState

    @Test func installStateNotInstalledWhenClean() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    @Test func installStateInstalledAfterInstall() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .installed)
    }

    @Test func installStateNotInstalledAfterUninstall() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        _ = try installer.uninstall(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    @Test func installStateModifiedExternallyWhenCommandEdited() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // Tamper: change the command in the installed entry.
        let settingsPath = home.path + "/.claude/settings.json"
        var dict = try readJSON(settingsPath)
        var hooks = dict["hooks"] as! [String: Any]
        var startArr = hooks["SessionStart"] as! [[String: Any]]
        var innerHooks = startArr[0]["hooks"] as! [[String: Any]]
        innerHooks[0]["command"] = "adrafinil acquire TAMPERED --tool claude-code"
        startArr[0] = ["hooks": innerHooks]
        hooks["SessionStart"] = startArr
        dict["hooks"] = hooks
        let tampered = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try tampered.write(to: URL(fileURLWithPath: settingsPath))

        #expect(installer.installState(for: .claudeCode) == .modifiedExternally)
    }

    // MARK: - Aider wrapper (both rc files + script)

    @Test func aiderInstallWritesToBothRCFiles() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        // Pre-create rc files and make aider detectable.
        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        // Override PATH detection by using a fake binaryOnPath; instead, directly call
        // install via the spec to avoid the isDetected gate.
        // We test via HookInstaller but bypass detection by creating a fake binary.
        let binDir = home.path + "/.local/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binDir + "/aider", contents: nil)
        chmod(binDir + "/aider", 0o755)

        // Use HookSpec directly to sidestep PATH-based isDetected.
        let spec = HookSpec.for(agent: .aider, cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try spec.install(dryRun: false)

        let zshrc  = try String(contentsOfFile: home.path + "/.zshrc", encoding: .utf8)
        let bashrc = try String(contentsOfFile: home.path + "/.bashrc", encoding: .utf8)

        #expect(zshrc.contains("# adrafinil-aider"), "zshrc must contain marker")
        #expect(bashrc.contains("# adrafinil-aider"), "bashrc must contain marker")
        #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/aider-adrafinil"), "wrapper script must be written")
        #expect(!result.summary.isEmpty)
    }

    @Test func aiderUninstallStripsFromBothRCFilesAndRemovesScript() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let spec = HookSpec.for(agent: .aider, cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try spec.install(dryRun: false)
        let result = try spec.uninstall(dryRun: false)

        let zshrc  = try String(contentsOfFile: home.path + "/.zshrc", encoding: .utf8)
        let bashrc = try String(contentsOfFile: home.path + "/.bashrc", encoding: .utf8)

        #expect(!zshrc.contains("adrafinil-aider"), "zshrc must not contain marker after uninstall")
        #expect(!bashrc.contains("adrafinil-aider"), "bashrc must not contain marker after uninstall")
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.local/bin/aider-adrafinil"),
                "wrapper script must be removed")
        #expect(!result.diff.isEmpty)
    }

    @Test func aiderInstallStateInstalledWhenBothRCsAndScriptPresent() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let spec = HookSpec.for(agent: .aider, cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try spec.install(dryRun: false)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .aider) == .installed)
    }

    // MARK: - Cursor (different JSON shape)

    @Test func installCursorWritesFlatShape() throws {
        let home = try makeFakeHome(detectedDirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .cursor, dryRun: false)

        let dict = try readJSON(home.path + "/.cursor/hooks.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startArr = try #require(hooks["sessionStart"] as? [[String: Any]])
        #expect(startArr.first?["command"] is String)
    }
}
