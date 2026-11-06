import Foundation
import Testing
@testable import AdrafinilShared

@Suite("ClaudeSessionDirectories")
struct ClaudeSessionDirectoriesTests {
    private func dirs(existing: Set<String>? = nil) -> ClaudeSessionDirectories {
        ClaudeSessionDirectories(homeRoot: "/Users/me") { path in existing?.contains(path) ?? true }
    }

    @Test
    func `default directory comes first and alone when nothing is learned`() {
        let d = dirs()
        #expect(d.sessionsDirectories.map(\.path) == ["/Users/me/.claude/sessions"])
    }

    @Test
    func `accepts a home relative profile dir`() {
        var d = dirs()
        let r1 = d.register("/Users/me/.claude-work")
        #expect(r1)
        #expect(d.sessionsDirectories.map(\.path) == ["/Users/me/.claude/sessions", "/Users/me/.claude-work/sessions"])
    }

    /// Reported paths are untrusted socket input.
    @Test
    func `rejects paths outside home, relative, default, or traversing out`() {
        let d = dirs()
        #expect(d.validated("/tmp/.claude-work") == nil)
        #expect(d.validated("/Users/meow/.claude") == nil, "a sibling home sharing a prefix is not inside home")
        #expect(d.validated("/Users/me") == nil, "home itself is not a profile dir")
        #expect(d.validated("/Users/me/../other/.claude") == nil)
        #expect(d.validated(".claude-work") == nil)
        #expect(d.validated("~/.claude-work") == nil, "only absolute paths — the CLI sends what the env holds")
        #expect(d.validated("/Users/me/.claude") == nil)
        #expect(d.validated("/Users/me/x/../.claude/") == nil)
        #expect(d.validated("") == nil)
        #expect(d.validated(nil) == nil)
        #expect(d.validated("/Users/me/" + String(repeating: "a", count: 2_000)) == nil)
        #expect(d.validated("/Users/me/x/../.claude-work/") == "/Users/me/.claude-work")
    }

    @Test
    func `requires a sessions subdirectory`() {
        var d = dirs(existing: ["/Users/me/.claude-work"])
        let r2 = d.register("/Users/me/.claude-other")
        #expect(!r2)
        let r3 = d.register("/Users/me/.claude-work")
        #expect(r3)
        #expect(d.learned == ["/Users/me/.claude-work"])
    }

    @Test
    func `re-report moves to most recent and the set is capped`() {
        var d = dirs()
        for i in 0 ..< ClaudeSessionDirectories.maxCount {
            d.register("/Users/me/p\(i)")
        }
        let r4 = d.register("/Users/me/p\(ClaudeSessionDirectories.maxCount - 1)")
        #expect(!r4, "already most recent")
        let r5 = d.register("/Users/me/p0")
        #expect(r5, "moves to most recent")
        #expect(d.learned.last == "/Users/me/p0")
        #expect(d.learned.count == ClaudeSessionDirectories.maxCount)

        let r6 = d.register("/Users/me/new")
        #expect(r6)
        #expect(d.learned.count == ClaudeSessionDirectories.maxCount)
        #expect(!d.learned.contains("/Users/me/p1"), "the oldest is evicted")
        #expect(d.learned.contains("/Users/me/p0"))
        #expect(d.learned.last == "/Users/me/new")
    }
}
