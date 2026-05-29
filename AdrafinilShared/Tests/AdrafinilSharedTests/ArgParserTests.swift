import Testing
@testable import AdrafinilShared

@Suite("ArgParser")
struct ArgParserTests {

    @Test func positionalsCollectedInOrder() {
        let p = ArgParser(args: ["foo", "bar", "baz"])
        #expect(p.positionals == ["foo", "bar", "baz"])
        #expect(p.positional(0) == "foo")
        #expect(p.positional(2) == "baz")
        #expect(p.positional(99) == nil)
    }

    @Test func optionWithSpaceSeparatedValue() {
        let p = ArgParser(args: ["--tool", "claude-code"])
        #expect(p.option("--tool") == "claude-code")
    }

    @Test func optionWithEqualsSyntax() {
        let p = ArgParser(args: ["--tool=claude-code", "--reason=tests"])
        #expect(p.option("--tool") == "claude-code")
        #expect(p.option("--reason") == "tests")
    }

    @Test func flagWithoutValueIsRecognized() {
        let p = ArgParser(args: ["--dry-run"])
        #expect(p.flag("--dry-run"))
        #expect(p.option("--dry-run") == nil)
    }

    @Test func flagFollowedByAnotherFlag() {
        let p = ArgParser(args: ["--dry-run", "--json"])
        #expect(p.flag("--dry-run"))
        #expect(p.flag("--json"))
    }

    @Test func mixedPositionalsOptionsFlags() {
        let p = ArgParser(args: ["session-key-123", "--tool", "codex", "--reason", "running tests", "--json"])
        #expect(p.positional(0) == "session-key-123")
        #expect(p.option("--tool") == "codex")
        #expect(p.option("--reason") == "running tests")
        #expect(p.flag("--json"))
    }

    @Test func emptyArgs() {
        let p = ArgParser(args: [])
        #expect(p.positionals.isEmpty)
        #expect(p.options.isEmpty)
        #expect(p.flags.isEmpty)
    }

    @Test func unknownOptionReturnsNil() {
        let p = ArgParser(args: ["--tool", "claude-code"])
        #expect(p.option("--missing") == nil)
        #expect(p.flag("--missing") == false)
    }

    @Test func dryRunFlagParsedAlongsideTool() {
        let p = ArgParser(args: ["--tool", "claude-code", "--dry-run"])
        #expect(p.option("--tool") == "claude-code")
        #expect(p.flag("--dry-run"))
    }

    @Test func dryRunFlagParsedBeforeTool() {
        let p = ArgParser(args: ["--dry-run", "--tool", "aider"])
        #expect(p.flag("--dry-run"))
        #expect(p.option("--tool") == "aider")
    }

    @Test func equalsSyntaxWithEmptyValue() {
        let p = ArgParser(args: ["--reason="])
        #expect(p.option("--reason") == "")
        #expect(p.flag("--reason") == false)
    }

    @Test func repeatedOptionTakesLastValue() {
        let p = ArgParser(args: ["--tool", "a", "--tool", "b"])
        #expect(p.option("--tool") == "b")
    }
}
