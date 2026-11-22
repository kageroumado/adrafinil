import Foundation
import Testing
@testable import AdrafinilShared

@Suite("HookInstaller")
struct HookInstallerTests {
    /// Creates a tempdir-rooted fake home with the given subdirs pre-created so
    /// `isDetected()` returns true for the target agents.
    func makeFakeHome(detectedDirs: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in detectedDirs {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }

    func readJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func writeJSON(_ object: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Detection

    @Test
    func `detects claude code by config dir`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let detected = HookInstaller.detectedAgents(homeRoot: home.path)
        #expect(detected.contains(.claudeCode))
        #expect(!detected.contains(.codex))
    }

    @Test
    func `detects all tier 1 when all present`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude", ".codex", ".cursor", ".gemini", ".gemini/antigravity-cli", ".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        // Seed a Gemini CLI file alongside Antigravity's subdir so both share ~/.gemini cleanly.
        try writeJSON([:], to: home.path + "/.gemini/settings.json")
        let detected = Set(HookInstaller.detectedAgents(homeRoot: home.path))
        #expect(detected.isSuperset(of: [.claudeCode, .codex, .cursor, .geminiCLI, .devin, .antigravity]))
    }

    @Test
    func `devin is detected when its config dir exists`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }

        let detected = HookInstaller.detectedAgents(homeRoot: home.path)

        #expect(detected.contains(.devin))
    }

    @Test(arguments: [".gemini/antigravity-cli", ".gemini/antigravity", ".gemini/antigravity-ide"])
    func `antigravity is detected by each surface directory without false-detecting gemini cli`(dir: String) throws {
        let home = try makeFakeHome(detectedDirs: [dir, ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }

        let detected = HookInstaller.detectedAgents(homeRoot: home.path)

        #expect(detected.contains(.antigravity))
        #expect(!detected.contains(.geminiCLI), "an Antigravity-only ~/.gemini dir must not false-detect Gemini CLI")
    }

    @Test
    func `gemini cli is still detected when ~/.gemini holds its own files alongside antigravity`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli", ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }
        try writeJSON([:], to: home.path + "/.gemini/settings.json")

        let detected = HookInstaller.detectedAgents(homeRoot: home.path)

        #expect(detected.contains(.antigravity))
        #expect(detected.contains(.geminiCLI))
    }

    // MARK: - Uninstall

    @Test
    func `uninstall removes only adrafinil entries`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        // Seed a user hook first, under the same event we wire.
        let existing: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": "echo user-hook"]]]],
            ],
        ]
        let settingsPath = home.path + "/.claude/settings.json"
        let data = try JSONSerialization.data(withJSONObject: existing, options: [])
        try data.write(to: URL(fileURLWithPath: settingsPath))

        _ = try installer.install(for: .claudeCode, dryRun: false)
        try installer.uninstall(for: .claudeCode)

        let dict = try readJSON(settingsPath)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["UserPromptSubmit"] as? [Any])
        #expect(startEntries.count == 1, "uninstall must leave the user's hook intact")
    }

    @Test
    func `uninstall dry run does not touch disk`() throws {
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

    @Test
    func `install state not installed when clean`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `install state installed after install`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .installed)
    }

    @Test
    func `install state not installed after uninstall`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        _ = try installer.uninstall(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    @Test
    func `install state modified externally when command edited`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // Tamper: change the command in the installed entry.
        let settingsPath = home.path + "/.claude/settings.json"
        var dict = try readJSON(settingsPath)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        var startArr = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        var innerHooks = try #require(startArr[0]["hooks"] as? [[String: Any]])
        innerHooks[0]["command"] = "adrafinil acquire TAMPERED --tool claude-code"
        startArr[0] = ["hooks": innerHooks]
        hooks["UserPromptSubmit"] = startArr
        dict["hooks"] = hooks
        let tampered = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try tampered.write(to: URL(fileURLWithPath: settingsPath))

        #expect(installer.installState(for: .claudeCode) == .modifiedExternally)
    }
}
