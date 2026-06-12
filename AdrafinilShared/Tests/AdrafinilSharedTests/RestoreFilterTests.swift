import Foundation
import Testing
@testable import AdrafinilShared

/// Restored state must never re-pin sleep on behalf of processes that no longer exist: after a
/// reboot every stored PID is recycled, and a stale assertion whose pid lands on a busy system
/// process would hold `disablesleep` for up to the 24h backstop.
@Suite("RestoreFilter")
struct RestoreFilterTests {
    private func assertion(key: String = "claude-code:abc", pid: pid_t = 500, name: String = "claude-code", acquiredAt: Date) -> Assertion {
        Assertion(key: key, tool: "claude-code", pid: pid, processName: name, acquiredAt: acquiredAt)
    }

    @Test
    func `assertions acquired before boot are dropped even if their pid is live`() {
        let boot = Date()
        let stale = assertion(acquiredAt: boot.addingTimeInterval(-3_600))
        let outcome = RestoreFilter.partition([stale], bootTime: boot) { _ in "/usr/local/bin/claude" }
        #expect(outcome.kept.isEmpty)
        #expect(outcome.dropped.count == 1)
    }

    @Test
    func `a recycled pid pointing at an unrelated binary is dropped`() {
        let boot = Date().addingTimeInterval(-100)
        let a = assertion(acquiredAt: Date())
        let outcome = RestoreFilter.partition([a], bootTime: boot) { _ in "/usr/libexec/mdworker" }
        #expect(outcome.kept.isEmpty)
    }

    @Test
    func `a dead pid is dropped`() {
        let boot = Date().addingTimeInterval(-100)
        let a = assertion(acquiredAt: Date())
        let outcome = RestoreFilter.partition([a], bootTime: boot) { _ in nil }
        #expect(outcome.kept.isEmpty)
    }

    @Test
    func `a live matching assertion from this boot is kept`() {
        let boot = Date().addingTimeInterval(-100)
        let a = assertion(acquiredAt: Date())
        let outcome = RestoreFilter.partition([a], bootTime: boot) { _ in "/usr/local/bin/claude" }
        #expect(outcome.kept.count == 1)
    }

    @Test
    func `a pid-less sentinel assertion from this boot is kept`() {
        let boot = Date().addingTimeInterval(-100)
        let a = assertion(pid: -1, acquiredAt: Date())
        let outcome = RestoreFilter.partition([a], bootTime: boot) { _ in nil }
        #expect(outcome.kept.count == 1, "no pid to validate — kept; the idle sweep and backstop govern it")
    }

    @Test
    func `nil boot time skips only the reboot check`() {
        let a = assertion(acquiredAt: Date.distantPast)
        let kept = RestoreFilter.partition([a], bootTime: nil) { _ in "/usr/local/bin/claude" }
        #expect(kept.kept.count == 1)
        let dropped = RestoreFilter.partition([a], bootTime: nil) { _ in "/usr/libexec/mdworker" }
        #expect(dropped.kept.isEmpty)
    }

    @Test
    func `name matching tolerates tool labels and versioned install paths`() {
        // Stored names are tool labels, not necessarily executable basenames.
        #expect(RestoreFilter.executablePlausiblyMatches(
            storedName: "claude-code",
            currentPath: "/Users/u/.local/share/claude/versions/2.1.156",
        ), "the versioned basename doesn't match, but the claude path component does")
        #expect(RestoreFilter.executablePlausiblyMatches(
            storedName: "codex", currentPath: "/opt/homebrew/bin/codex",
        ))
        #expect(!RestoreFilter.executablePlausiblyMatches(
            storedName: "claude-code", currentPath: "/System/Library/CoreServices/WindowServer",
        ))
        // Trivially short components must not create accidental matches.
        #expect(!RestoreFilter.executablePlausiblyMatches(
            storedName: "claude-code", currentPath: "/bin/sh",
        ))
    }

    @Test
    func `system boot time is available and in the past`() throws {
        let boot = try #require(RestoreFilter.systemBootTime())
        #expect(boot < Date())
    }
}

@Suite("PersistedDaemonState")
struct PersistedDaemonStateTests {
    @Test
    func `envelope round-trips assertions and paused`() throws {
        let state = PersistedDaemonState(
            assertions: [Assertion(key: "k", tool: "t", pid: 1, processName: "p")],
            paused: true,
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try #require(PersistedDaemonState.decode(from: data))
        #expect(decoded.paused)
        #expect(decoded.assertions.first?.key == "k")
    }

    @Test
    func `legacy bare-array state files decode with paused false`() throws {
        let legacy = try JSONEncoder().encode([Assertion(key: "k", tool: "t", pid: 1, processName: "p")])
        let decoded = try #require(PersistedDaemonState.decode(from: legacy))
        #expect(!decoded.paused)
        #expect(decoded.assertions.count == 1)
    }

    @Test
    func `garbage state files decode as nil`() {
        #expect(PersistedDaemonState.decode(from: Data("not json".utf8)) == nil)
    }
}
