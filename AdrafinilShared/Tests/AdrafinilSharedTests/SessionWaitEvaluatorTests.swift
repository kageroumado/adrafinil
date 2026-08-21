import Foundation
import Testing
@testable import AdrafinilShared

@Suite("SessionWaitEvaluator")
struct SessionWaitEvaluatorTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func sessionAssertion(_ sessionID: String, pid: pid_t = 500, expiresAt: Date? = nil) -> Assertion {
        var a = Assertion(
            key: "claude-code:\(sessionID)",
            tool: "claude-code",
            pid: pid,
            processName: "claude",
            acquiredAt: now.addingTimeInterval(-300),
        )
        a.expiresAt = expiresAt
        return a
    }

    private func status(_ sessionID: String, _ activity: ClaudeSessionStatus.Activity, pid: pid_t = 500, waitingFor: String? = nil) -> ClaudeSessionStatus {
        ClaudeSessionStatus(pid: pid, sessionID: sessionID, activity: activity, waitingFor: waitingFor, statusUpdatedAt: now)
    }

    private func config(_ policy: AgentWaitingPolicy, graceSeconds: TimeInterval = 600) -> SessionWaitEvaluator.Config {
        .init(policy: policy, graceSeconds: graceSeconds)
    }

    private func evaluate(
        _ evaluator: inout SessionWaitEvaluator,
        assertions: [Assertion],
        statuses: [ClaudeSessionStatus],
        policy: AgentWaitingPolicy = .grace,
        graceSeconds: TimeInterval = 600,
        at time: Date? = nil,
    ) -> [SessionWaitEvaluator.Action] {
        evaluator.evaluate(
            assertions: assertions,
            statuses: statuses,
            now: time ?? now,
            config: config(policy, graceSeconds: graceSeconds),
            pidAlive: { _ in true },
        )
    }

    @Test
    func `grace parks a waiting hold and restores it on busy`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")

        let parked = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting, waitingFor: "approve Bash")])
        #expect(parked == [
            .setWaitingFor(key: a.key, label: "approve Bash"),
            .park(key: a.key, expiresAt: now.addingTimeInterval(600)),
        ])
        #expect(e.hasParked)

        // Still waiting: no repeated actions.
        var stillParked = e
        #expect(evaluate(&stillParked, assertions: [a], statuses: [status("s1", .waiting, waitingFor: "approve Bash")]).isEmpty)

        // Answered (keyboard, phone, or timeout — all just flip the file to busy).
        let restored = evaluate(&e, assertions: [a], statuses: [status("s1", .busy)])
        #expect(restored == [
            .setWaitingFor(key: a.key, label: nil),
            .restore(key: a.key, expiry: nil),
        ])
        #expect(!e.hasParked)
    }

    /// A hold that already carries a shorter TTL (Cursor-style backstop) must never be *extended*
    /// by the grace window.
    @Test
    func `grace never extends an existing shorter expiry`() {
        var e = SessionWaitEvaluator()
        let soon = now.addingTimeInterval(120)
        let a = sessionAssertion("s1", expiresAt: soon)

        let actions = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)])
        #expect(actions.contains(.park(key: a.key, expiresAt: soon)))

        // And the restore puts the *original* expiry back, not nil.
        let restored = evaluate(&e, assertions: [a], statuses: [status("s1", .busy)])
        #expect(restored.contains(.restore(key: a.key, expiry: soon)))
    }

    /// Grace TTL ran out and the idle sweep released the hold; the session is answered later
    /// (e.g. the Mac slept, woke, and the user replied) — the resumed turn gets its hold back.
    @Test
    func `grace reacquires after the released hold's session turns busy`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")
        _ = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)])

        // Hold gone (TTL expiry), still waiting: nothing to do, but the entry stays parked.
        #expect(evaluate(&e, assertions: [], statuses: [status("s1", .waiting)]).isEmpty)
        #expect(e.hasParked)

        let resumed = evaluate(&e, assertions: [], statuses: [status("s1", .busy)])
        guard case let .reacquire(reacquired)? = resumed.first, resumed.count == 1 else {
            Issue.record("expected a single reacquire, got \(resumed)")
            return
        }
        #expect(reacquired.key == a.key)
        #expect(reacquired.expiresAt == nil)
        #expect(reacquired.waitingFor == nil)
        #expect(!e.hasParked)
    }

    @Test
    func `sleep releases immediately and reacquires on busy`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")

        let actions = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting, waitingFor: "input needed")], policy: .sleep)
        #expect(actions == [
            .setWaitingFor(key: a.key, label: "input needed"),
            .release(key: a.key),
        ])

        let resumed = evaluate(&e, assertions: [], statuses: [status("s1", .busy)], policy: .sleep)
        guard case .reacquire? = resumed.first else {
            Issue.record("expected reacquire, got \(resumed)")
            return
        }
    }

    /// `.keepAwake` still marks the wait (the popover says "waiting for you") but never touches
    /// the hold.
    @Test
    func `keepAwake only marks`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")

        let actions = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)], policy: .keepAwake)
        #expect(actions == [.setWaitingFor(key: a.key, label: "input needed")])
        #expect(!e.hasParked)

        let cleared = evaluate(&e, assertions: [a], statuses: [status("s1", .busy)], policy: .keepAwake)
        #expect(cleared == [.setWaitingFor(key: a.key, label: nil)])
    }

    /// `waiting → idle` (the user's answer ended the whole turn): restore, never re-acquire.
    @Test
    func `idle resolves a parked wait without reacquiring`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")
        _ = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)])

        let live = evaluate(&e, assertions: [a], statuses: [status("s1", .idle)])
        #expect(live.contains(.restore(key: a.key, expiry: nil)))

        // Same but the hold was already gone (sleep policy / TTL): the entry just drops.
        var e2 = SessionWaitEvaluator()
        _ = evaluate(&e2, assertions: [a], statuses: [status("s1", .waiting)], policy: .sleep)
        #expect(evaluate(&e2, assertions: [], statuses: [status("s1", .idle)], policy: .sleep).isEmpty)
        #expect(!e2.hasParked)
    }

    /// A dead session (pid gone, or its file swept) can never trigger a re-acquire — the normal
    /// nets own that hold's fate, and this evaluator stands down.
    @Test
    func `dead or vanished sessions drop parked state`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")
        _ = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)], policy: .sleep)

        #expect(evaluate(&e, assertions: [], statuses: []).isEmpty)
        #expect(!e.hasParked)

        // Dead pid variant: the status exists but its process doesn't.
        var e2 = SessionWaitEvaluator()
        _ = evaluate(&e2, assertions: [a], statuses: [status("s1", .waiting)], policy: .sleep)
        let actions = e2.evaluate(
            assertions: [],
            statuses: [status("s1", .busy)],
            now: now,
            config: config(.sleep),
            pidAlive: { _ in false },
        )
        #expect(actions.isEmpty)
        #expect(!e2.hasParked)
    }

    /// A parked hold whose session file vanishes while the hold is still live: restore and stand
    /// down rather than leaving a grace TTL armed with nothing to ever clear it.
    @Test
    func `vanished status restores a live parked hold`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")
        _ = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting)])

        let actions = evaluate(&e, assertions: [a], statuses: [])
        #expect(actions.contains(.restore(key: a.key, expiry: nil)))
        #expect(actions.contains(.setWaitingFor(key: a.key, label: nil)))
        #expect(!e.hasParked)
    }

    /// Everything that isn't a per-turn Claude Code session hold is out of scope: manual holds,
    /// other agents, sub-agent / background-shell keys with no matching session file.
    @Test
    func `only claude code session holds are touched`() {
        var e = SessionWaitEvaluator()
        var manual = sessionAssertion("s1")
        manual = Assertion(
            key: manual.key, tool: manual.tool, pid: manual.pid, processName: manual.processName,
            acquiredAt: manual.acquiredAt, ttl: 3_600, origin: .manual,
        )
        let cursor = Assertion(key: "cursor:s2", tool: "cursor", pid: 600, processName: "cursor", acquiredAt: now)
        let subagent = sessionAssertion("agent-abc123")
        let bgShell = sessionAssertion("bg-39750244")

        let actions = evaluate(
            &e,
            assertions: [manual, cursor, subagent, bgShell],
            statuses: [status("s1", .waiting), status("s2", .waiting)],
        )
        #expect(actions.isEmpty)
        #expect(!e.hasParked)
    }

    /// The waiting label follows the dialog: a permission prompt replacing a question re-labels
    /// the same wait without re-parking it.
    @Test
    func `label changes re-mark without re-parking`() {
        var e = SessionWaitEvaluator()
        let a = sessionAssertion("s1")
        _ = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting, waitingFor: "input needed")])

        let relabeled = evaluate(&e, assertions: [a], statuses: [status("s1", .waiting, waitingFor: "approve Bash")])
        #expect(relabeled == [.setWaitingFor(key: a.key, label: "approve Bash")])
    }
}
