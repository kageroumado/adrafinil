import Foundation
import Testing
@testable import AdrafinilShared

extension HookInstallerTests {
    // MARK: - Aider wrapper (both rc files + script)

    @Test
    func `aider install writes to both RC files`() throws {
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

        // Use the integration directly to sidestep PATH-based isDetected.
        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try AiderIntegration().install(ctx, dryRun: false)

        let zshrc = try String(contentsOfFile: home.path + "/.zshrc", encoding: .utf8)
        let bashrc = try String(contentsOfFile: home.path + "/.bashrc", encoding: .utf8)

        #expect(zshrc.contains("# adrafinil-aider"), "zshrc must contain marker")
        #expect(bashrc.contains("# adrafinil-aider"), "bashrc must contain marker")
        #expect(FileManager.default.fileExists(atPath: home.path + "/.local/bin/aider-adrafinil"), "wrapper script must be written")
        #expect(!result.summary.isEmpty)
    }

    /// Regression: the wrapper's `release` must carry the same `--tool` as its `acquire`. Without it,
    /// `release` defaults to tool `unknown` and targets the key `unknown:$$` — which never exists —
    /// so the real `aider:$$` hold leaks until the daemon's dead-process net reaps it (and never, if
    /// the PID couldn't be resolved at acquire time).
    @Test
    func `aider wrapper script acquire and release both carry tool`() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().install(ctx, dryRun: false)

        let script = try String(contentsOfFile: home.path + "/.local/bin/aider-adrafinil", encoding: .utf8)
        #expect(script.contains("acquire $$ --tool aider"), "acquire must tag the hold with --tool aider")
        #expect(script.contains("release $$ --tool aider"), "release must target the same key acquire created")
        #expect(!script.contains("release $$\n"), "release must not drop --tool (would target unknown:$$)")
    }

    @Test
    func `aider uninstall strips from both RC files and removes script`() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().install(ctx, dryRun: false)
        let result = try AiderIntegration().uninstall(ctx, dryRun: false)

        let zshrc = try String(contentsOfFile: home.path + "/.zshrc", encoding: .utf8)
        let bashrc = try String(contentsOfFile: home.path + "/.bashrc", encoding: .utf8)

        #expect(!zshrc.contains("adrafinil-aider"), "zshrc must not contain marker after uninstall")
        #expect(!bashrc.contains("adrafinil-aider"), "bashrc must not contain marker after uninstall")
        #expect(
            !FileManager.default.fileExists(atPath: home.path + "/.local/bin/aider-adrafinil"),
            "wrapper script must be removed",
        )
        #expect(!result.diff.isEmpty)
    }

    @Test
    func `aider install state installed when both R cs and script present`() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }

        try "".write(toFile: home.path + "/.zshrc", atomically: true, encoding: .utf8)
        try "".write(toFile: home.path + "/.bashrc", atomically: true, encoding: .utf8)

        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try AiderIntegration().install(ctx, dryRun: false)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .aider) == .installed)
    }

    // MARK: - Cursor (different JSON shape)

    @Test
    func `install cursor writes flat shape`() throws {
        let home = try makeFakeHome(detectedDirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .cursor, dryRun: false)

        let dict = try readJSON(home.path + "/.cursor/hooks.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let acquireArr = try #require(hooks["beforeSubmitPrompt"] as? [[String: Any]])
        let acquire = try #require(acquireArr.first?["command"] as? String)
        #expect(acquire.contains("acquire --tool cursor"))
        #expect(acquire.contains("--ttl \(CursorIntegration.holdTTLSeconds)"), "the acquire must be TTL-capped — `stop` is the only release signal")
        let releaseArr = try #require(hooks["stop"] as? [[String: Any]])
        #expect((releaseArr.first?["command"] as? String)?.contains("release --tool cursor") == true)
    }

    /// The 1.5.1 shape (issue #15): session-scoped hooks left holds pinned to the long-lived Cursor
    /// app. The once-per-build reinstall must *move* the entries to the turn-scoped events — a merge
    /// that leaves the old `sessionStart` acquire firing would keep the exact bug it migrates away
    /// from — while foreign entries under those same events survive.
    @Test
    func `cursor reinstall migrates session-scoped hooks to turn-scoped events`() throws {
        let home = try makeFakeHome(detectedDirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }

        let old: [String: Any] = [
            "version": 1,
            "hooks": [
                "sessionStart": [
                    ["command": "/Applications/Adrafinil.app/Contents/Helpers/adrafinil acquire --tool cursor", "_adrafinil": true],
                    ["command": "echo user-hook"],
                ],
                "sessionEnd": [
                    ["command": "/Applications/Adrafinil.app/Contents/Helpers/adrafinil release --tool cursor", "_adrafinil": true],
                ],
            ],
        ]
        let path = home.path + "/.cursor/hooks.json"
        try JSONSerialization.data(withJSONObject: old).write(to: URL(fileURLWithPath: path))

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .cursor) == .modifiedExternally, "the old shape must read as drifted so the build migration reinstalls it")
        _ = try installer.install(for: .cursor, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        let start = try #require(hooks["sessionStart"] as? [[String: Any]])
        #expect(start.count == 1, "our stale sessionStart acquire must be stripped")
        #expect(start.first?["command"] as? String == "echo user-hook")
        #expect(hooks["sessionEnd"] == nil, "an event emptied of our entries must be dropped")
        #expect(hooks["beforeSubmitPrompt"] != nil)
        #expect(hooks["stop"] != nil)
        #expect(installer.installState(for: .cursor) == .installed)
    }

    // MARK: - Devin (nested JSON shape, stdin session id)

    /// All handler commands wired under `event` in a nested-shape hooks dict (empty when absent).
    private func devinHookCommands(_ hooks: [String: Any], event: String) -> [String] {
        ((hooks[event] as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    /// Devin's config file lives at `~/.config/devin/config.json` inside a fake home.
    private func devinConfigPath(_ home: URL) -> String {
        home.path + "/.config/devin/config.json"
    }

    /// The exact commands the integration writes. Asserting equality on them doubles as the "no
    /// session positional" check — Devin exposes no session-id env var, so the id is sourced from
    /// stdin and any `$…` positional would be a bug.
    private static let devinAcquire = "/usr/local/bin/adrafinil acquire --tool devin"
    private static let devinRelease = "/usr/local/bin/adrafinil release --tool devin"

    @Test
    func `devin install acquires on UserPromptSubmit`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let hooks = try #require(try readJSON(devinConfigPath(home))["hooks"] as? [String: Any])
        #expect(devinHookCommands(hooks, event: "UserPromptSubmit") == [Self.devinAcquire])
    }

    @Test
    func `devin install releases on Stop`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let hooks = try #require(try readJSON(devinConfigPath(home))["hooks"] as? [String: Any])
        #expect(devinHookCommands(hooks, event: "Stop") == [Self.devinRelease])
    }

    /// `SessionEnd` is release-only cleanup for a session that ends without a `Stop` — never an
    /// acquire, which would re-introduce the session-scoped hold this integration avoids.
    @Test
    func `devin install releases on SessionEnd`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let hooks = try #require(try readJSON(devinConfigPath(home))["hooks"] as? [String: Any])
        #expect(devinHookCommands(hooks, event: "SessionEnd") == [Self.devinRelease])
    }

    @Test
    func `devin install reports installed`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        #expect(installer.installState(for: .devin) == .installed)
    }

    /// `~/.config/devin/config.json` holds Devin's own top-level keys alongside `hooks` — install
    /// must add ours without touching them.
    @Test
    func `devin install preserves Devin's own settings`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = devinConfigPath(home)
        try writeJSON([
            "agent": ["model": "default"],
            "permissions": ["allow": ["Exec(go version)"]],
            "theme_mode": "dark",
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let dict = try readJSON(path)
        #expect((dict["agent"] as? [String: String]) == ["model": "default"])
        #expect((dict["permissions"] as? [String: [String]]) == ["allow": ["Exec(go version)"]])
        #expect(dict["theme_mode"] as? String == "dark")
    }

    /// Devin's real config file is 0600; the atomic rewrite must keep it that way.
    @Test
    func `devin install keeps the config file's 0600 permissions`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = devinConfigPath(home)
        try writeJSON(["version": 1], to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test
    func `devin uninstall removes every Adrafinil hook`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        try installer.uninstall(for: .devin)

        let hooks = try (readJSON(devinConfigPath(home))["hooks"] as? [String: Any]) ?? [:]
        let commands = hooks.keys.flatMap { devinHookCommands(hooks, event: $0) }
        #expect(commands.allSatisfy { !$0.contains("adrafinil") })
    }

    @Test
    func `devin uninstall keeps the user's own hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = devinConfigPath(home)
        try writeJSON([
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/user-stop"]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)
        try installer.uninstall(for: .devin)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(devinHookCommands(hooks, event: "Stop") == ["/usr/local/bin/user-stop"])
    }

    @Test
    func `devin uninstall reports not installed`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        try installer.uninstall(for: .devin)

        #expect(installer.installState(for: .devin) == .notInstalled)
    }

    /// A config missing the `SessionEnd` release (e.g. a partial write) must read as
    /// `.modifiedExternally` so the UI nudges a reinstall — not `.notInstalled`, which would hide
    /// the live entries.
    @Test
    func `devin config missing its SessionEnd release reads as modified externally`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = devinConfigPath(home)
        try writeJSON([
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": Self.devinAcquire, "_adrafinil": true]]]],
                "Stop": [["hooks": [["type": "command", "command": Self.devinRelease, "_adrafinil": true]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let state = installer.installState(for: .devin)

        #expect(state == .modifiedExternally)
    }

    @Test
    func `devin reinstall restores a missing SessionEnd release`() throws {
        let home = try makeFakeHome(detectedDirs: [".config/devin"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = devinConfigPath(home)
        try writeJSON([
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": Self.devinAcquire, "_adrafinil": true]]]],
                "Stop": [["hooks": [["type": "command", "command": Self.devinRelease, "_adrafinil": true]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .devin, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(devinHookCommands(hooks, event: "SessionEnd") == [Self.devinRelease])
    }

    // MARK: - Antigravity (named hooks.json shape, camelCase stdin conversationId)

    private func antigravityConfigPath(_ home: URL) -> String {
        home.path + "/.gemini/config/hooks.json"
    }

    private static let antigravityAcquire = "/usr/local/bin/adrafinil acquire --tool antigravity"
    private static let antigravityRelease = "/usr/local/bin/adrafinil release --tool antigravity"

    @Test
    func `antigravity install writes named PreInvocation and Stop hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .antigravity, dryRun: false)

        let dict = try readJSON(antigravityConfigPath(home))
        let entry = try #require(dict["adrafinil"] as? [String: Any])
        let pre = try #require(entry["PreInvocation"] as? [[String: Any]])
        let stop = try #require(entry["Stop"] as? [[String: Any]])
        #expect(pre.count == 1)
        #expect(pre.first?["type"] as? String == "command")
        #expect(pre.first?["command"] as? String == Self.antigravityAcquire)
        #expect(stop.count == 1)
        #expect(stop.first?["type"] as? String == "command")
        #expect(stop.first?["command"] as? String == Self.antigravityRelease)
        #expect(installer.installState(for: .antigravity) == .installed)
    }

    @Test
    func `antigravity install and uninstall preserve sibling named hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli", ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = antigravityConfigPath(home)
        let sibling: [String: Any] = [
            "PreInvocation": [["type": "command", "command": "/bin/sh -c 'echo {}'"]],
            "Stop": [["type": "command", "command": "/bin/sh -c 'echo {}'"]],
        ]
        try writeJSON(["orca-status": sibling], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .antigravity, dryRun: false)
        var dict = try readJSON(path)
        #expect(dict["orca-status"] != nil, "sibling named hooks must survive install")
        #expect(dict["adrafinil"] != nil)

        try installer.uninstall(for: .antigravity)
        dict = try readJSON(path)
        #expect(dict["adrafinil"] == nil, "uninstall must remove the adrafinil named hook")
        let kept = try #require(dict["orca-status"] as? [String: Any])
        #expect(NSDictionary(dictionary: kept).isEqual(to: sibling), "sibling named hooks must survive uninstall verbatim")
        #expect(installer.installState(for: .antigravity) == .notInstalled)
    }

    @Test
    func `antigravity install is idempotent and dry run does not touch disk`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)

        let dry = try installer.install(for: .antigravity, dryRun: true)
        #expect(!dry.diff.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: antigravityConfigPath(home)))

        _ = try installer.install(for: .antigravity, dryRun: false)
        let second = try installer.install(for: .antigravity, dryRun: false)
        #expect(second.diff == "(unchanged)")
    }

    @Test
    func `antigravity installState detects drift and reinstall repairs it`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli", ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = antigravityConfigPath(home)
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .antigravity, dryRun: false)

        // Disabled hook or missing Stop must report `.modifiedExternally`.
        var dict = try readJSON(path)
        var entry = try #require(dict["adrafinil"] as? [String: Any])
        entry["enabled"] = false
        dict["adrafinil"] = entry
        try writeJSON(dict, to: path)
        #expect(installer.installState(for: .antigravity) == .modifiedExternally)

        _ = try installer.install(for: .antigravity, dryRun: false)
        #expect(installer.installState(for: .antigravity) == .installed)

        // Missing Stop event alone also reads as drift.
        try writeJSON([
            "adrafinil": [
                "PreInvocation": [["type": "command", "command": Self.antigravityAcquire]],
            ],
        ], to: path)
        #expect(installer.installState(for: .antigravity) == .modifiedExternally)

        _ = try installer.install(for: .antigravity, dryRun: false)
        #expect(installer.installState(for: .antigravity) == .installed)
    }

    @Test
    func `antigravity refuses an unparseable hooks json on install and uninstall`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli", ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = antigravityConfigPath(home)
        try "{ broken".write(toFile: path, atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .antigravity) == .configUnreadable)
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer.install(for: .antigravity, dryRun: false)
        }
        #expect(throws: HookInstaller.SkipReason.self) {
            try installer.uninstall(for: .antigravity)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{ broken")
    }

    @Test
    func `antigravity install preserves file permissions and uninstall is no-op when absent`() throws {
        let home = try makeFakeHome(detectedDirs: [".gemini/antigravity-cli", ".gemini/config"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)

        let noop = try installer.uninstall(for: .antigravity)
        #expect(noop.diff == "(unchanged)")

        let path = antigravityConfigPath(home)
        try writeJSON([:], to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        _ = try installer.install(for: .antigravity, dryRun: false)
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}
