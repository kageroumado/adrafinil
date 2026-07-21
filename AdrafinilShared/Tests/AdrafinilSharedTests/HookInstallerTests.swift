import Foundation
import Testing
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

    private func writeJSON(_ object: [String: Any], to path: String) throws {
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
        let home = try makeFakeHome(detectedDirs: [".claude", ".codex", ".cursor", ".gemini"])
        defer { try? FileManager.default.removeItem(at: home) }
        let detected = Set(HookInstaller.detectedAgents(homeRoot: home.path))
        #expect(detected.isSuperset(of: [.claudeCode, .codex, .cursor, .geminiCLI]))
    }

    // MARK: - Install: Claude Code shape

    @Test
    func `install claude code writes activity scoped hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try installer.install(for: .claudeCode, dryRun: false)

        #expect(result.summary.contains("UserPromptSubmit"))
        #expect(result.summary.contains("Stop"))

        let path = home.path + "/.claude/settings.json"
        let dict = try readJSON(path)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
        // Session-scoped events must not be wired — that was the whole-session-hold bug.
        #expect(hooks["SessionStart"] == nil)
        #expect(hooks["SessionEnd"] == nil)

        // Esc-interrupt release: Notification matched to idle_prompt, carrying the release command.
        let notif = try #require(hooks["Notification"] as? [[String: Any]])
        let entry = try #require(notif.first { ($0["matcher"] as? String) == "idle_prompt" })
        let inner = try #require(entry["hooks"] as? [[String: Any]])
        #expect((inner.first?["command"] as? String)?.contains("release") == true)
        #expect((inner.first?["command"] as? String)?.contains("claude-code") == true)
    }

    /// The sub-agent fix (issue #7): Claude Code gets `SubagentStart` → `acquire --subagent` and
    /// `SubagentStop` → `release --subagent`, keyed on the sub-agent's `agent_id` from stdin (so no
    /// `$CLAUDE_CODE_SESSION_ID` positional — that would be the parent's session).
    @Test
    func `install claude code writes subagent hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let hooks = try #require(try readJSON(home.path + "/.claude/settings.json")["hooks"] as? [String: Any])

        func command(under event: String) throws -> String {
            let arr = try #require(hooks[event] as? [[String: Any]], "\(event) present")
            let inner = try #require(arr.first?["hooks"] as? [[String: Any]])
            return try #require(inner.first?["command"] as? String)
        }

        let start = try command(under: "SubagentStart")
        #expect(start.contains("acquire --tool claude-code --subagent"))
        #expect(!start.contains("$CLAUDE_CODE_SESSION_ID"), "sub-agent id comes from stdin, not the parent session env var")

        let stop = try command(under: "SubagentStop")
        #expect(stop.contains("release --tool claude-code --subagent"))
        #expect(!stop.contains("$CLAUDE_CODE_SESSION_ID"))
    }

    @Test
    func `uninstall claude code removes subagent hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)

        _ = try installer.install(for: .claudeCode, dryRun: false)
        try installer.uninstall(for: .claudeCode)

        let hooks = try #require(try readJSON(home.path + "/.claude/settings.json")["hooks"] as? [String: Any])
        #expect(hooks["SubagentStart"] == nil, "our SubagentStart entry must be gone")
        #expect(hooks["SubagentStop"] == nil, "our SubagentStop entry must be gone")
        #expect(installer.installState(for: .claudeCode) == .notInstalled)
    }

    /// A pre-#7 install (UserPromptSubmit/Stop/Notification present, but no sub-agent hooks) is a
    /// partial install now — it must read as `.modifiedExternally` so the UI nudges a reinstall that
    /// adds them, NOT as `.notInstalled` (which would hide the live entries).
    @Test
    func `install state modified when subagent hooks missing`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // Simulate the pre-#7 state: drop the two sub-agent hooks only.
        let path = home.path + "/.claude/settings.json"
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        hooks["SubagentStart"] = nil
        hooks["SubagentStop"] = nil
        dict["hooks"] = hooks
        try writeJSON(dict, to: path)

        #expect(installer.installState(for: .claudeCode) == .modifiedExternally)

        // Reinstall self-heals: it re-adds the sub-agent hooks and the state flips back to installed.
        _ = try installer.install(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .installed)
    }

    @Test
    func `uninstall claude code removes notification hook`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)

        _ = try installer.install(for: .claudeCode, dryRun: false)
        #expect(installer.installState(for: .claudeCode) == .installed)
        try installer.uninstall(for: .claudeCode)
        #expect(installer.installState(for: .claudeCode) == .notInstalled)

        let hooks = try #require(try readJSON(home.path + "/.claude/settings.json")["hooks"] as? [String: Any])
        let notif = (hooks["Notification"] as? [[String: Any]]) ?? []
        #expect(notif.allSatisfy { ($0["matcher"] as? String) != "idle_prompt" }, "our Notification entry must be gone")
    }

    /// An install missing the Notification release (a build predating it) must read as not-fully-installed
    /// so the UI nudges a reinstall that adds it.
    @Test
    func `install state not installed when notification hook missing`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        // Simulate the pre-idle_prompt state: drop the Notification hook only.
        let path = home.path + "/.claude/settings.json"
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        hooks["Notification"] = nil
        dict["hooks"] = hooks
        try writeJSON(dict, to: path)

        #expect(installer.installState(for: .claudeCode) == .modifiedExternally)
    }

    /// Upgrading from the old `SessionStart`/`SessionEnd` wiring must strip the stale acquire/release
    /// entries, or a lingering `SessionStart` → acquire would keep re-introducing the whole-session hold.
    @Test
    func `install claude code migrates away from session scoped hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"

        try writeJSON([
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "adrafinil acquire $CLAUDE_CODE_SESSION_ID --tool claude-code", "_adrafinil": true]]]],
                "SessionEnd": [["hooks": [["type": "command", "command": "adrafinil release $CLAUDE_CODE_SESSION_ID --tool claude-code", "_adrafinil": true]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(hooks["SessionStart"] == nil, "obsolete event dropped entirely, not left as an empty array")
        #expect(hooks["SessionEnd"] == nil, "obsolete event dropped entirely, not left as an empty array")
        #expect(installer.installState(for: .claudeCode) == .installed)
    }

    /// A user's own `SessionStart` hook must survive the migration cleanup untouched.
    @Test
    func `migration preserves user session start hook`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.claude/settings.json"

        try writeJSON([
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "adrafinil acquire X --tool claude-code", "_adrafinil": true]]],
                    ["hooks": [["type": "command", "command": "echo my-own-hook"]]],
                ],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(sessionStart.count == 1)
        let inner = try #require(sessionStart.first?["hooks"] as? [[String: Any]])
        #expect(inner.first?["command"] as? String == "echo my-own-hook")
    }

    @Test
    func `install codex writes user prompt submit and sources id from stdin`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)

        let dict = try readJSON(home.path + "/.codex/hooks.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        // Codex acquires on UserPromptSubmit (fires every turn, new session or resumed — unlike
        // SessionStart, which a resume skips) and releases on Stop (fires at turn completion, when
        // control returns to the user). Per-turn bracketing, mirroring Claude Code.
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil, "Stop fires at turn completion — the release boundary")
        #expect(hooks["SessionStart"] == nil, "SessionStart misses resumed sessions — UserPromptSubmit instead")
        #expect(hooks["SessionEnd"] == nil)

        // Codex's shape is the nested matcher-group form (verified on-device and against the official
        // figma plugin): the event holds groups, each wrapping an inner `hooks` array of
        // `{ "type": "command", "command": … }` handlers — same as Claude Code. The flat (no-wrapper)
        // form is silently ignored. `matcher` is omitted (no tool to match on these lifecycle events)
        // and there is no `_adrafinil` marker key, which Codex's strict deserializer may reject.
        let start = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        let group = try #require(start.first)
        #expect(group["matcher"] == nil, "no tool to match on prompt submit — no matcher")
        let handlers = try #require(group["hooks"] as? [[String: Any]], "must be nested — inner hooks wrapper")
        let entry = try #require(handlers.first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["_adrafinil"] == nil, "no marker key — Codex may reject unknown fields")
        let cmd = try #require(entry["command"] as? String)
        // Codex exposes no session-id env var — the id comes from stdin `session_id`, so the
        // command carries no `$…` positional and definitely no fictional $CODEX_THREAD_ID.
        #expect(!cmd.contains("CODEX_THREAD_ID"))
        #expect(!cmd.contains("$"))
        #expect(cmd.contains("acquire --tool codex"))

        // The Stop handler is the symmetric release: same nested shape, no marker key, no env var.
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let stopGroup = try #require(stop.first)
        #expect(stopGroup["matcher"] == nil, "no tool to match on turn end — no matcher")
        let stopHandlers = try #require(stopGroup["hooks"] as? [[String: Any]], "must be nested — inner hooks wrapper")
        let stopEntry = try #require(stopHandlers.first)
        #expect(stopEntry["type"] as? String == "command")
        #expect(stopEntry["_adrafinil"] == nil, "no marker key — Codex may reject unknown fields")
        let stopCmd = try #require(stopEntry["command"] as? String)
        #expect(!stopCmd.contains("$"))
        #expect(stopCmd.contains("release --tool codex"))
    }

    /// Trust isn't stored in hooks.json — Codex records a `trusted_hash` in config.toml keyed by the
    /// handler's position *and* a hash of its command. So re-installing must keep our handler at a
    /// stable index with an unchanged command (and not churn sibling keys), or the position/hash no
    /// longer matches and the user must re-approve.
    @Test
    func `reinstalling codex keeps the handler stable so trust survives`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)

        let path = home.path + "/.codex/hooks.json"
        // Capture our handler's command, then simulate Codex adding a sibling key to the handler.
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        var groups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
        let originalCommand = try #require(handlers[0]["command"] as? String)
        handlers[0]["sibling"] = "keep-me"
        groups[0]["hooks"] = handlers
        hooks["UserPromptSubmit"] = groups
        dict["hooks"] = hooks
        try writeJSON(dict, to: path)

        _ = try installer.install(for: .codex, dryRun: false)

        let after = try readJSON(path)
        let outGroups = try #require((after["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(outGroups.count == 1, "reinstall must not duplicate the group")
        let outHandlers = try #require(outGroups[0]["hooks"] as? [[String: Any]])
        #expect(outHandlers.count == 1, "reinstall must not duplicate the handler")
        #expect(outHandlers[0]["command"] as? String == originalCommand, "command unchanged so the trust hash still matches")
        #expect(outHandlers[0]["sibling"] as? String == "keep-me", "sibling keys preserved")
    }

    /// Upgrading from the old `SessionStart` wiring (which a resume skipped) to `UserPromptSubmit`
    /// must strip our stale `SessionStart` handler, or it would keep double-firing on new sessions.
    @Test
    func `install codex strips a stale SessionStart entry`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.codex/hooks.json"

        // Seed a legacy adrafinil SessionStart hook plus a user's own SessionStart hook.
        try writeJSON([
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "/usr/local/bin/adrafinil acquire --tool codex"]]],
                    ["hooks": [["type": "command", "command": "/usr/local/bin/user-thing"]]],
                ],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        // Our handler moved to UserPromptSubmit; the legacy SessionStart group is gone but the user's
        // own SessionStart hook is left untouched.
        #expect((hooks["UserPromptSubmit"] as? [[String: Any]])?.count == 1)
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(sessionStart.count == 1, "only the user's own SessionStart group remains")
        let userCmd = ((sessionStart[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(userCmd == "/usr/local/bin/user-thing")
    }

    @Test
    func `fresh codex install reads as installed`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)
        #expect(installer.installState(for: .codex) == .installed)
    }

    /// A config from the build that wired only `UserPromptSubmit` (no `Stop` release) is a partial
    /// install once we manage both — it must read as externally-modified so the UI nudges a reinstall
    /// that adds the missing release, not as `.installed`.
    @Test
    func `codex install missing the Stop release reads as modified`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.codex/hooks.json"

        // Only the acquire handler, exactly as the previous (release-less) build wrote it.
        try writeJSON([
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "/usr/local/bin/adrafinil acquire --tool codex"]]],
                ],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .codex) == .modifiedExternally, "acquire-only is a partial install")

        // Reinstalling self-heals: it adds the Stop release and the state flips to installed.
        _ = try installer.install(for: .codex, dryRun: false)
        #expect(installer.installState(for: .codex) == .installed)
        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(hooks["Stop"] != nil)
    }

    /// The sub-agent fix (issue #7) for Codex: `SubagentStart` → `acquire --subagent` and
    /// `SubagentStop` → `release --subagent`, in the same nested matcher-group shape, keyed on the
    /// sub-agent's `agent_id` from stdin.
    @Test
    func `install codex writes subagent hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)

        let hooks = try #require(try readJSON(home.path + "/.codex/hooks.json")["hooks"] as? [String: Any])

        func command(under event: String) throws -> String {
            let groups = try #require(hooks[event] as? [[String: Any]], "\(event) present")
            let inner = try #require(groups.first?["hooks"] as? [[String: Any]], "nested hooks wrapper")
            return try #require(inner.first?["command"] as? String)
        }

        let start = try command(under: "SubagentStart")
        #expect(start.contains("acquire --tool codex --subagent"))
        #expect(!start.contains("$"), "Codex sources the sub-agent id from stdin — no env var")

        let stop = try command(under: "SubagentStop")
        #expect(stop.contains("release --tool codex --subagent"))
        #expect(!stop.contains("$"))
    }

    /// A pre-#7 Codex install (UserPromptSubmit/Stop only) is partial once we also manage the sub-agent
    /// hooks — `.modifiedExternally`, self-healed by reinstall, and never `.notInstalled`.
    @Test
    func `codex install missing the subagent hooks reads as modified`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.codex/hooks.json"

        // Acquire + release, but no sub-agent hooks — exactly the previous build's output.
        try writeJSON([
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": "/usr/local/bin/adrafinil acquire --tool codex"]]]],
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/adrafinil release --tool codex"]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(installer.installState(for: .codex) == .modifiedExternally, "missing sub-agent hooks is a partial install")

        _ = try installer.install(for: .codex, dryRun: false)
        #expect(installer.installState(for: .codex) == .installed)
        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(hooks["SubagentStart"] != nil)
        #expect(hooks["SubagentStop"] != nil)
    }

    @Test
    func `uninstall codex removes subagent hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)

        _ = try installer.install(for: .codex, dryRun: false)
        _ = try installer.uninstall(for: .codex, dryRun: false)

        let hooks = try #require(try readJSON(home.path + "/.codex/hooks.json")["hooks"] as? [String: Any])
        #expect(hooks["SubagentStart"] == nil)
        #expect(hooks["SubagentStop"] == nil)
        #expect(installer.installState(for: .codex) == .notInstalled)
    }

    /// Each event carries its own `config.toml` trust hash keyed by command+position, so a reinstall
    /// must leave *both* the acquire and the release handler byte-stable (and not churn sibling keys),
    /// or the user is forced to re-approve in `/hooks`.
    @Test
    func `reinstalling codex keeps both handlers stable so trust survives`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)
        let path = home.path + "/.codex/hooks.json"

        // Simulate Codex annotating each of our handlers with a sibling key (as it does on trust).
        var dict = try readJSON(path)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        for event in ["UserPromptSubmit", "Stop"] {
            var groups = try #require(hooks[event] as? [[String: Any]])
            var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
            handlers[0]["sibling"] = "keep-\(event)"
            groups[0]["hooks"] = handlers
            hooks[event] = groups
        }
        dict["hooks"] = hooks
        try writeJSON(dict, to: path)

        _ = try installer.install(for: .codex, dryRun: false)

        let after = try #require(try readJSON(path)["hooks"] as? [String: Any])
        for (event, op) in [("UserPromptSubmit", "acquire"), ("Stop", "release")] {
            let groups = try #require(after[event] as? [[String: Any]], "\(event) present")
            #expect(groups.count == 1, "\(event): no duplicate group")
            let handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(handlers.count == 1, "\(event): no duplicate handler")
            #expect((handlers[0]["command"] as? String)?.contains("\(op) --tool codex") == true)
            #expect(handlers[0]["sibling"] as? String == "keep-\(event)", "\(event): sibling key preserved")
        }
    }

    /// Uninstall strips both the acquire and release handlers, leaving the user's own hooks intact.
    @Test
    func `uninstall codex removes both acquire and release`() throws {
        let home = try makeFakeHome(detectedDirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.path + "/.codex/hooks.json"

        // Seed a user's own Stop hook so we can prove uninstall leaves it alone.
        try writeJSON([
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/user-stop"]]]],
            ],
        ], to: path)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)
        _ = try installer.uninstall(for: .codex, dryRun: false)

        let hooks = try #require(try readJSON(path)["hooks"] as? [String: Any])
        #expect(hooks["UserPromptSubmit"] == nil, "our acquire is gone")
        // Our Stop handler is gone but the user's own Stop hook survives in its group.
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let stopCmds = stop.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        #expect(stopCmds == ["/usr/local/bin/user-stop"], "user's own Stop hook preserved, ours removed")
        #expect(installer.installState(for: .codex) == .notInstalled)
    }

    @Test
    func `install pi writes extension with correct events`() throws {
        let home = try makeFakeHome(detectedDirs: [".pi"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .pi, dryRun: false)

        let path = home.path + "/.pi/agent/extensions/adrafinil.ts"
        let ts = try String(contentsOfFile: path, encoding: .utf8)
        #expect(ts.contains("session_start"))
        #expect(ts.contains("session_shutdown"))
        #expect(ts.contains("--tool"))
        #expect(installer.installState(for: .pi) == .installed)
    }

    @Test
    func `install open code uses info id and no idle release`() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }
        // OpenCode is binary-detected; install via the integration directly to bypass the PATH gate.
        let ctx = HookContext(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try OpenCodeIntegration().install(ctx, dryRun: false)

        let path = home.path + "/.config/opencode/plugins/adrafinil.ts"
        let ts = try String(contentsOfFile: path, encoding: .utf8)
        #expect(ts.contains("event.properties.info.id"), "must use the correct session-id accessor")
        #expect(!ts.contains("session.idle"), "must not release on the per-turn session.idle event")
        #expect(ts.contains("session.created"))
    }

    @Test
    func `install hermes writes shell hook and allowlist`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        // Seed a realistic Hermes config with the default empty hooks map.
        try "model:\n  default: x\nhooks: {}\nhooks_auto_accept: false\n"
            .write(toFile: home.path + "/.hermes/config.yaml", atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .hermes, dryRun: false)

        // Shell hook lives in config.yaml's hooks: map — NOT a Python plugin.
        let cfg = try String(contentsOfFile: home.path + "/.hermes/config.yaml", encoding: .utf8)
        #expect(cfg.contains("on_session_start"))
        #expect(cfg.contains("pre_gateway_dispatch"))
        #expect(cfg.contains("on_session_end"))
        #expect(cfg.contains("acquire --tool hermes"))
        #expect(!cfg.contains("HERMES_SESSION_ID"))
        #expect(!cfg.contains("hooks: {}"), "empty hooks map should have been replaced")

        // Every (event, command) pair must be allowlisted or Hermes skips that hook.
        let allow = try Data(contentsOf: URL(fileURLWithPath: home.path + "/.hermes/shell-hooks-allowlist.json"))
        let approvals = try #require(try (JSONSerialization.jsonObject(with: allow) as? [String: Any])?["approvals"] as? [[String: Any]])
        #expect(approvals.count == 3)
        #expect(approvals.contains { ($0["event"] as? String) == "on_session_start" })
        #expect(approvals.contains { ($0["event"] as? String) == "pre_gateway_dispatch" })
        #expect(approvals.contains { ($0["event"] as? String) == "on_session_end" })

        #expect(installer.installState(for: .hermes) == .installed)
    }

    @Test
    func `hermes uninstall restores empty hooks and revokes allowlist`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        try "model:\n  default: x\nhooks: {}\nhooks_auto_accept: false\n"
            .write(toFile: home.path + "/.hermes/config.yaml", atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .hermes, dryRun: false)
        try installer.uninstall(for: .hermes)

        let cfg = try String(contentsOfFile: home.path + "/.hermes/config.yaml", encoding: .utf8)
        #expect(!cfg.contains("adrafinil"), "our hooks must be gone")
        #expect(cfg.contains("hooks: {}"), "empty hooks map should be restored")
        #expect(installer.installState(for: .hermes) == .notInstalled)
    }

    /// Regression: uninstall must restore only the top-level `hooks:` map we own — a *nested* `hooks:`
    /// elsewhere in the user's YAML must survive untouched. A global `replacingOccurrences(of:"hooks:\n")`
    /// matched the tail of an indented `      hooks:\n` and rewrote that nested map to `hooks: {}`.
    @Test
    func `hermes uninstall leaves nested hooks map intact`() throws {
        let home = try makeFakeHome(detectedDirs: [".hermes"])
        defer { try? FileManager.default.removeItem(at: home) }
        // A user config with an unrelated nested `hooks:` map *and* the default top-level empty one.
        try "agents:\n  sub:\n    hooks:\n      on_x:\n        - command: \"echo hi\"\nhooks: {}\n"
            .write(toFile: home.path + "/.hermes/config.yaml", atomically: true, encoding: .utf8)

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .hermes, dryRun: false)
        try installer.uninstall(for: .hermes)

        let cfg = try String(contentsOfFile: home.path + "/.hermes/config.yaml", encoding: .utf8)
        #expect(!cfg.contains("adrafinil"), "our hooks must be gone")
        #expect(cfg.contains("    hooks:\n      on_x:"), "the nested hooks map must be preserved verbatim")
        #expect(cfg.contains("echo hi"), "nested hook command must survive")
        #expect(cfg.contains("hooks: {}"), "the top-level map we owned is restored to empty")
    }

    @Test
    func `install is idempotent`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let dict = try readJSON(home.path + "/.claude/settings.json")
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["UserPromptSubmit"] as? [Any])
        #expect(startEntries.count == 1, "double-install should not duplicate hook entries")
    }

    @Test
    func `install preserves existing user hooks`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        // User already has a hook configured under the same event we wire.
        let existing: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "echo user-hook"]]],
                ],
            ],
        ]
        let settingsPath = home.path + "/.claude/settings.json"
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try existingData.write(to: URL(fileURLWithPath: settingsPath))

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .claudeCode, dryRun: false)

        let dict = try readJSON(settingsPath)
        let hooks = try #require(dict["hooks"] as? [String: Any])
        let startEntries = try #require(hooks["UserPromptSubmit"] as? [Any])
        #expect(startEntries.count == 2, "must preserve the user's existing hook alongside ours")
    }

    @Test
    func `dry run does not touch disk`() throws {
        let home = try makeFakeHome(detectedDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        let result = try installer.install(for: .claudeCode, dryRun: true)

        #expect(!result.diff.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.claude/settings.json"))
    }

    @Test
    func `install skips undetected agent`() throws {
        let home = try makeFakeHome(detectedDirs: [])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        #expect(throws: HookInstaller.SkipReason.self) {
            _ = try installer.install(for: .claudeCode, dryRun: false)
        }
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
}
