import Foundation
import Testing
@testable import AdrafinilShared

/// Tests our Codex hook *model* against a faithful mock of how the real Codex parses and dispatches
/// `hooks.json`, modeled on codex-rs `config/src/hook_config.rs` plus the `protocol`/`hooks` schema:
///
///  * Config is `{ "hooks": { "<Event>": [ <MatcherGroup> ] } }`. `HooksFile` is strict
///    (`deny_unknown_fields` — only `description`+`hooks`); `MatcherGroup` (`{ matcher?, hooks }`) is
///    lenient (extra keys ignored); a command handler is the internally-tagged `{ "type": "command",
///    "command": … }` (extra keys tolerated, as serde's `#[serde(tag = "type")]` enum does).
///  * Event keys are CamelCase (`UserPromptSubmit`, `Stop`).
///  * Every hook is handed a stdin JSON payload carrying snake_case `session_id`.
///  * `UserPromptSubmit` fires on each prompt submission; `Stop` fires when the turn completes and
///    control returns to the user (codex-rs `session/turn.rs` runs the stop hooks only when
///    `!needs_follow_up`).
///
/// The mock routes an event to our installed command handlers and derives the registry key the CLI
/// would (`session_id` from stdin → `ManualHold.sessionKey`), so the assertions exercise the real
/// shared key rule rather than a reimplementation of it.
@Suite("CodexHookModel")
struct CodexHookModelTests {
    // MARK: - Faithful mock of Codex's config model

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }
        init(_ s: String) {
            stringValue = s
        }
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        init?(intValue _: Int) {
            nil
        }
    }

    /// Mirrors `HooksFile` — strict: only `description` and `hooks` are allowed at the top level, so a
    /// stray sibling key fails the decode exactly as `#[serde(deny_unknown_fields)]` does.
    private struct CodexHooksFile: Decodable {
        let hooks: CodexHookEvents
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let allowed: Set = ["description", "hooks"]
            for key in c.allKeys where !allowed.contains(key.stringValue) {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: c.codingPath,
                    debugDescription: "unknown field `\(key.stringValue)` (HooksFile denies unknown fields)",
                ))
            }
            hooks = try c.decodeIfPresent(CodexHookEvents.self, forKey: AnyKey("hooks")) ?? CodexHookEvents()
        }
    }

    /// The event→groups map (`HookEventsToml`); CamelCase keys, each absent event meaning no groups.
    private struct CodexHookEvents: Decodable {
        var byEvent: [String: [CodexMatcherGroup]] = [:]
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            for key in c.allKeys {
                byEvent[key.stringValue] = try c.decode([CodexMatcherGroup].self, forKey: key)
            }
        }

        func groups(for event: String) -> [CodexMatcherGroup] {
            byEvent[event] ?? []
        }
    }

    /// Mirrors `MatcherGroup` — lenient: `matcher` and `hooks` both default, any other key ignored.
    /// This is *why* a flat `[{type,command}]` array is silently ignored: each flat element decodes to
    /// a group with no `hooks`, contributing zero handlers.
    private struct CodexMatcherGroup: Decodable {
        let matcher: String?
        let hooks: [CodexHandler]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            matcher = try c.decodeIfPresent(String.self, forKey: AnyKey("matcher"))
            hooks = try c.decodeIfPresent([CodexHandler].self, forKey: AnyKey("hooks")) ?? []
        }
    }

    /// Mirrors the `HookHandlerConfig::Command` variant (internally tagged by `type`); extra keys are
    /// tolerated, exactly as serde's internally-tagged enum is.
    private struct CodexHandler: Decodable {
        let type: String
        let command: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            type = try c.decode(String.self, forKey: AnyKey("type"))
            command = try c.decodeIfPresent(String.self, forKey: AnyKey("command"))
        }
    }

    // MARK: - Mock hook engine

    /// One registry operation our hooks drive.
    private struct Op: Equatable {
        let op: String
        let key: String
    }

    /// Parses `… adrafinil <op> --tool <tool>` out of a hook command string, as the CLI's arg parser
    /// would see it.
    private func invocation(in command: String) -> (op: String, tool: String)? {
        let toks = command.split(separator: " ").map(String.init)
        guard let cmdIdx = toks.firstIndex(where: { $0 == "acquire" || $0 == "release" }),
              let toolIdx = toks.firstIndex(of: "--tool"), toolIdx + 1 < toks.count else { return nil }
        return (toks[cmdIdx], toks[toolIdx + 1])
    }

    /// Dispatches `event` with a stdin payload carrying `session_id == sessionId`, returning the ops
    /// our command handlers perform — keyed via the *real* shared rule the CLI uses, so the test can't
    /// drift from production key derivation.
    private func dispatch(_ file: CodexHooksFile, event: String, sessionId: String) -> [Op] {
        var ops: [Op] = []
        for group in file.hooks.groups(for: event) {
            for handler in group.hooks where handler.type == "command" {
                guard let cmd = handler.command,
                      ConfigFileIO.commandInvokesAdrafinilCLI(cmd),
                      let inv = invocation(in: cmd) else { continue }
                ops.append(Op(op: inv.op, key: ManualHold.sessionKey(tool: inv.tool, sessionID: sessionId)))
            }
        }
        return ops
    }

    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return dir
    }

    /// Installs our real Codex hooks into a fake home, then parses the on-disk file through the mock —
    /// so a config our installer can't actually produce a valid Codex parse of fails here.
    private func install(_ home: URL) throws -> CodexHooksFile {
        let installer = HookInstaller(cliPath: "/usr/local/bin/adrafinil", homeRoot: home.path)
        _ = try installer.install(for: .codex, dryRun: false)
        let data = try Data(contentsOf: URL(fileURLWithPath: home.path + "/.codex/hooks.json"))
        return try JSONDecoder().decode(CodexHooksFile.self, from: data)
    }

    // MARK: - Tests

    @Test
    func `our installed config parses under codex's strict model and routes both events`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try install(home) // throws if our output violates the model (e.g. a stray top-level key)
        #expect(!file.hooks.groups(for: "UserPromptSubmit").isEmpty, "acquire must route on prompt submit")
        #expect(!file.hooks.groups(for: "Stop").isEmpty, "release must route on turn end")
    }

    @Test
    func `a turn brackets acquire and release on the same key`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try install(home)
        let sid = "0199abcd-thread-id"

        // UserPromptSubmit (turn begins) → acquire; Stop (turn completes) → release, same key.
        let acquire = dispatch(file, event: "UserPromptSubmit", sessionId: sid)
        let release = dispatch(file, event: "Stop", sessionId: sid)
        #expect(acquire == [Op(op: "acquire", key: "codex:\(sid)")])
        #expect(release == [Op(op: "release", key: "codex:\(sid)")])
        #expect(acquire.first?.key == release.first?.key, "release must target exactly the acquired key")
    }

    @Test
    func `a multi-turn session cycles one idempotent key`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try install(home)
        let sid = "session-A"

        // Codex resumes the same session id across turns, so every turn cycles acquire→release on the
        // one key — the next UserPromptSubmit re-acquires what the previous Stop released.
        var keys: Set<String> = []
        for _ in 0 ..< 3 {
            keys.formUnion(dispatch(file, event: "UserPromptSubmit", sessionId: sid).map(\.key))
            keys.formUnion(dispatch(file, event: "Stop", sessionId: sid).map(\.key))
        }
        #expect(keys == ["codex:\(sid)"], "one stable key for the whole session")
    }

    @Test
    func `concurrent sessions get distinct keys`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try install(home)
        let a = dispatch(file, event: "UserPromptSubmit", sessionId: "A")
        let b = dispatch(file, event: "UserPromptSubmit", sessionId: "B")
        #expect(a == [Op(op: "acquire", key: "codex:A")])
        #expect(b == [Op(op: "acquire", key: "codex:B")])
    }

    @Test
    func `the flat no-wrapper shape contributes no handlers`() throws {
        // The flat form Codex silently ignores: a handler placed directly in the event array with no
        // `hooks` wrapper. It decodes to a MatcherGroup with no handlers, so nothing fires — which is
        // exactly why our installer writes the nested matcher-group shape instead.
        let json = #"{"hooks":{"UserPromptSubmit":[{"type":"command","command":"/usr/local/bin/adrafinil acquire --tool codex"}]}}"#
        let file = try JSONDecoder().decode(CodexHooksFile.self, from: Data(json.utf8))
        #expect(
            dispatch(file, event: "UserPromptSubmit", sessionId: "x").isEmpty,
            "flat handlers have no `hooks` wrapper, so Codex (and our model) route nothing",
        )
    }

    @Test
    func `a stray top-level key is rejected like codex's strict HooksFile`() {
        let json = #"{"hooks":{},"bogus":1}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CodexHooksFile.self, from: Data(json.utf8))
        }
    }

    @Test
    func `an interrupted turn leaks no extra op and the next turn still releases`() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try install(home)
        let sid = "interrupted"

        // An Esc-interrupt aborts the turn and fires no Stop (codex-rs returns on TurnAborted before
        // run_turn_stop_hooks). So a turn that's interrupted produces only the acquire — the hold
        // lingers until a backstop or the next turn. The next prompt re-acquires (same idempotent key)
        // and *its* completion fires Stop, releasing the key. Model that: acquire, (no Stop), acquire,
        // Stop — the final state is a clean release of the single key.
        var live: Set<String> = []
        for op in dispatch(file, event: "UserPromptSubmit", sessionId: sid) {
            live.insert(op.key)
        }
        // ...interrupt: no Stop fires...
        for op in dispatch(file, event: "UserPromptSubmit", sessionId: sid) {
            live.insert(op.key)
        }
        #expect(live == ["codex:\(sid)"], "re-acquire is idempotent on the one key")
        for op in dispatch(file, event: "Stop", sessionId: sid) {
            live.remove(op.key)
        }
        #expect(live.isEmpty, "the next turn's Stop releases the key the interrupted turn left held")
    }
}
