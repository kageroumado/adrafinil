import Testing
@testable import AdrafinilShared

@Suite("ArgParser")
struct ArgParserTests {
    @Test
    func `positionals collected in order`() {
        let p = ArgParser(args: ["foo", "bar", "baz"])
        #expect(p.positionals == ["foo", "bar", "baz"])
        #expect(p.positional(0) == "foo")
        #expect(p.positional(2) == "baz")
        #expect(p.positional(99) == nil)
    }

    @Test
    func `option with space separated value`() {
        let p = ArgParser(args: ["--tool", "claude-code"])
        #expect(p.option("--tool") == "claude-code")
    }

    @Test
    func `option with equals syntax`() {
        let p = ArgParser(args: ["--tool=claude-code", "--reason=tests"])
        #expect(p.option("--tool") == "claude-code")
        #expect(p.option("--reason") == "tests")
    }

    @Test
    func `flag without value is recognized`() {
        let p = ArgParser(args: ["--dry-run"])
        #expect(p.flag("--dry-run"))
        #expect(p.option("--dry-run") == nil)
    }

    @Test
    func `flag followed by another flag`() {
        let p = ArgParser(args: ["--dry-run", "--json"])
        #expect(p.flag("--dry-run"))
        #expect(p.flag("--json"))
    }

    @Test
    func `mixed positionals options flags`() {
        let p = ArgParser(args: ["session-key-123", "--tool", "codex", "--reason", "running tests", "--json"])
        #expect(p.positional(0) == "session-key-123")
        #expect(p.option("--tool") == "codex")
        #expect(p.option("--reason") == "running tests")
        #expect(p.flag("--json"))
    }

    @Test
    func `empty args`() {
        let p = ArgParser(args: [])
        #expect(p.positionals.isEmpty)
        #expect(p.options.isEmpty)
        #expect(p.flags.isEmpty)
    }

    @Test
    func `unknown option returns nil`() {
        let p = ArgParser(args: ["--tool", "claude-code"])
        #expect(p.option("--missing") == nil)
        #expect(p.flag("--missing") == false)
    }

    @Test
    func `dry run flag parsed alongside tool`() {
        let p = ArgParser(args: ["--tool", "claude-code", "--dry-run"])
        #expect(p.option("--tool") == "claude-code")
        #expect(p.flag("--dry-run"))
    }

    @Test
    func `dry run flag parsed before tool`() {
        let p = ArgParser(args: ["--dry-run", "--tool", "aider"])
        #expect(p.flag("--dry-run"))
        #expect(p.option("--tool") == "aider")
    }

    @Test
    func `equals syntax with empty value`() {
        let p = ArgParser(args: ["--reason="])
        #expect(p.option("--reason") == "")
        #expect(p.flag("--reason") == false)
    }

    @Test
    func `repeated option takes last value`() {
        let p = ArgParser(args: ["--tool", "a", "--tool", "b"])
        #expect(p.option("--tool") == "b")
    }
}
