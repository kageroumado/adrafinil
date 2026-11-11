import Foundation
import Testing
@testable import AdrafinilShared

@Suite("CodexHookTrust")
struct CodexHookTrustTests {
    /// A temp home with `.codex/hooks.json` present (so status isn't `.unknown` for the wrong reason)
    /// and `config.toml` holding `tomlBody`.
    private func makeHome(configTOML: String?, hooksJSON: String? = "{\"hooks\":{}}") throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cxtrust-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        if let hooksJSON {
            try hooksJSON.write(to: codex.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        }
        if let configTOML {
            try configTOML.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        return home
    }

    /// A realistic config.toml: how Codex's toml_edit writer records hook trust (quoted dotted table
    /// headers, exactly like the `[projects."…"]` entries it writes).
    private func configTOML(home: URL, events: [String]) -> String {
        let path = "\(home.path)/.codex/hooks.json"
        var toml = "model = \"gpt-5.5\"\n\n[projects.\"/tmp\"]\ntrust_level = \"trusted\"\n\n"
        for event in events {
            toml += "[hooks.state.\"\(path):\(event):0:0\"]\ntrusted_hash = \"sha256:deadbeef\"\n\n"
        }
        return toml
    }

    @Test
    func `both events trusted reads as trusted`() throws {
        let home = try makeHome(configTOML: "")
        defer { try? FileManager.default.removeItem(at: home) }
        let toml = configTOML(home: home, events: ["user_prompt_submit", "stop"])
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexHookTrust.status(homeRoot: home.path) == .trusted)
    }

    @Test
    func `only one event trusted reads as partial`() throws {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let toml = configTOML(home: home, events: ["user_prompt_submit"]) // missing stop
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexHookTrust.status(homeRoot: home.path) == .partiallyTrusted)
    }

    @Test
    func `no trust entries reads as untrusted`() throws {
        let home = try makeHome(configTOML: "model = \"gpt-5.5\"\n[projects.\"/tmp\"]\ntrust_level = \"trusted\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodexHookTrust.status(homeRoot: home.path) == .untrusted)
    }

    @Test
    func `missing config toml reads as unknown`() throws {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodexHookTrust.status(homeRoot: home.path) == .unknown)
    }

    @Test
    func `missing hooks json reads as unknown`() throws {
        let home = try makeHome(configTOML: "model = \"x\"\n", hooksJSON: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodexHookTrust.status(homeRoot: home.path) == .unknown)
    }

    @Test
    func `an empty trusted hash does not count`() throws {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "\(home.path)/.codex/hooks.json"
        // Both keys present but with empty hashes (e.g. only an enabled flag was written) → untrusted.
        let toml = """
        [hooks.state."\(path):user_prompt_submit:0:0"]
        trusted_hash = ""
        enabled = true
        
        [hooks.state."\(path):stop:0:0"]
        enabled = true
        """
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexHookTrust.status(homeRoot: home.path) == .untrusted)
    }

    @Test
    func `trust recorded for a different hooks file does not count`() throws {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        // A trusted hook keyed to some *other* hooks.json (e.g. a project-level file) must not be read
        // as trust for our user-level hooks.
        let toml = """
        [hooks.state."/Users/someone/other/hooks.json:user_prompt_submit:0:0"]
        trusted_hash = "sha256:abc"
        
        [hooks.state."/Users/someone/other/hooks.json:stop:0:0"]
        trusted_hash = "sha256:abc"
        """
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexHookTrust.status(homeRoot: home.path) == .untrusted)
    }

    @Test
    func `trust at a non-zero group index still counts`() throws {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "\(home.path)/.codex/hooks.json"
        // The user has their own hooks before ours, so our handlers sit at group index 2 — the scan
        // matches on the path + event label, not a fixed index.
        let toml = """
        [hooks.state."\(path):user_prompt_submit:2:0"]
        trusted_hash = "sha256:abc"
        
        [hooks.state."\(path):stop:1:0"]
        trusted_hash = "sha256:def"
        """
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexHookTrust.status(homeRoot: home.path) == .trusted)
    }

    /// Status for a config.toml whose body is built from our hooks.json path.
    private func status(configTOML build: (String) -> String) throws -> CodexHookTrust.Status {
        let home = try makeHome(configTOML: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let toml = build("\(home.path)/.codex/hooks.json")
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        return CodexHookTrust.status(homeRoot: home.path)
    }

    @Test
    func `fully quoted table headers count`() throws {
        let status = try status { path in
            """
            ["hooks"."state"."\(path):user_prompt_submit:1:0"]
            trusted_hash = "sha256:abc"
            
            ['hooks'.'state'.'\(path):stop:1:0']
            trusted_hash = "sha256:def"
            """
        }
        #expect(status == .trusted)
    }

    @Test
    func `mixed quoting in table headers counts`() throws {
        let status = try status { path in
            """
            [hooks."state"."\(path):user_prompt_submit:0:0"]
            trusted_hash = "sha256:abc"
            
            ["hooks".state.'\(path):stop:0:0']
            trusted_hash = "sha256:def"
            """
        }
        #expect(status == .trusted)
    }

    @Test
    func `whitespace around dots in table headers counts`() throws {
        let status = try status { path in
            """
            [ hooks . state . "\(path):user_prompt_submit:0:0" ]
            trusted_hash = "sha256:abc"
            
            [hooks\t.\t"state" . "\(path):stop:0:0"]  # approved via /hooks
            trusted_hash = "sha256:def"
            """
        }
        #expect(status == .trusted)
    }

    @Test
    func `quoted trusted hash keys count`() throws {
        let status = try status { path in
            """
            [hooks.state."\(path):user_prompt_submit:0:0"]
            "trusted_hash" = "sha256:abc"
            
            [hooks.state."\(path):stop:0:0"]
            'trusted_hash'='sha256:def'
            """
        }
        #expect(status == .trusted)
    }

    @Test
    func `trust written as dotted keys under a parent table counts`() throws {
        let status = try status { path in
            """
            [hooks.state]
            "\(path):user_prompt_submit:0:0".trusted_hash = "sha256:abc"
            
            [hooks]
            state."\(path):stop:0:0"."trusted_hash" = "sha256:def"
            """
        }
        #expect(status == .trusted)
    }

    @Test
    func `trusted hash under a non matching table does not count`() throws {
        let status = try status { path in
            """
            ["hooks"."other"."\(path):user_prompt_submit:0:0"]
            trusted_hash = "sha256:abc"
            
            [hooks.state."\(path):stop:0:0".nested]
            trusted_hash = "sha256:def"
            
            [[hooks.state."\(path):stop:0:0"]]
            trusted_hash = "sha256:ghi"
            
            [projects."\(path):user_prompt_submit:0:0"]
            trusted_hash = "sha256:jkl"
            """
        }
        #expect(status == .untrusted)
    }

    @Test
    func `a header inside a multi line string is not read as a table`() throws {
        let status = try status { path in
            """
            notes = \"\"\"
            [hooks.state."\(path):user_prompt_submit:0:0"]
            trusted_hash = "sha256:abc"
            \"\"\"
            """
        }
        #expect(status == .untrusted)
    }

    @Test
    func `escapes in basic string keys are decoded before matching`() throws {
        let status = try status { path in
            let escaped = path.replacingOccurrences(of: "/", with: "\\u002F")
            return """
            ["hooks"."state"."\(escaped):user_prompt_submit:0:0"]
            trusted_hash = "sha256:abc"
            
            [hooks.state."\(path):stop:0:0"]
            trusted_hash = "sha256:def"
            """
        }
        #expect(status == .trusted)
    }
}
