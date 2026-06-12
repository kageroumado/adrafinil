import Foundation
import Testing
@testable import AdrafinilShared

/// Regressions for the cross-sweep bookkeeping: the evaluator's per-PID state outlives an
/// assertion (polling stops when nothing is held, then resumes), and stale baselines must never
/// release a freshly-acquired assertion mid-turn.
@Suite("IdleReleaseEvaluator bookkeeping")
struct IdleReleaseRegressionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func assertion(acquiredAt: Date, key: String = "k", pid: pid_t = 100, ttl: TimeInterval? = nil) -> Assertion {
        Assertion(key: key, tool: "codex", pid: pid, processName: "codex", acquiredAt: acquiredAt, ttl: ttl)
    }

    private func cfg(idle: TimeInterval = 90) -> IdleReleaseEvaluator.Config {
        .init(enabled: true, idleThresholdSeconds: idle, cpuRateThreshold: 0.03, maxAssertionAgeHours: 1_000)
    }

    /// A new assertion on a PID with stale bookkeeping (the previous assertion was released ten
    /// minutes ago, polling stopped, the agent starts a new turn) must NOT be released on its
    /// first sweep — neither by the gap-diluted rate nor by the stale idle clock.
    @Test
    func `a re-acquire on a pid with stale bookkeeping is not released on its first sweep`() {
        let e = IdleReleaseEvaluator()
        let first = assertion(acquiredAt: t0, key: "codex:turn1")

        // Turn 1: seed, go idle, get released at +91s.
        _ = e.evaluate(assertions: [first], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 10.0 })
        let released = e.evaluate(assertions: [first], now: t0.addingTimeInterval(91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 10.0 })
        #expect(released.map(\.reason) == [.cpuIdle])

        // Ten minutes later a new turn re-acquires on the SAME pid. The tree did a burst of real
        // work (5 CPU-seconds), but spread over the 600s gap that's a 0.008 rate — diluted below
        // the threshold. The fresh acquiredAt must win over the stale clock.
        let gapEnd = t0.addingTimeInterval(91 + 600)
        let second = assertion(acquiredAt: gapEnd.addingTimeInterval(-30), key: "codex:turn2")
        let out = e.evaluate(assertions: [second], now: gapEnd, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 15.0 })
        #expect(out.isEmpty, "a brand-new turn must never be cpuIdle-released on its first sweep")

        // And the re-seeded baseline measures rate from here: a busy next sweep stays held.
        let busy = e.evaluate(assertions: [second], now: gapEnd.addingTimeInterval(30), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 17.0 })
        #expect(busy.isEmpty)
    }

    /// `lastActivityAt` (advanced by the registry on every duplicate acquire) floors the idle
    /// clock: a hook re-acquire is an explicit activity signal.
    @Test
    func `a refreshed lastActivityAt resets the idle clock`() {
        let e = IdleReleaseEvaluator()
        var a = assertion(acquiredAt: t0)

        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 }) // seed
        _ = e.evaluate(assertions: [a], now: t0.addingTimeInterval(30), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })

        // The hook fires a re-acquire at +60s (registry stamps lastActivityAt); CPU stays flat.
        a.lastActivityAt = t0.addingTimeInterval(60)
        let held = e.evaluate(assertions: [a], now: t0.addingTimeInterval(120), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(held.isEmpty, "60s after the activity stamp is inside the 90s window")

        let released = e.evaluate(assertions: [a], now: t0.addingTimeInterval(60 + 91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(released.map(\.reason) == [.cpuIdle])
    }

    // MARK: Boundary pins

    @Test
    func `idle duration exactly at the threshold does not release`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        let atThreshold = e.evaluate(assertions: [a], now: t0.addingTimeInterval(90), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(atThreshold.isEmpty, "the rule is strictly past the window")
    }

    @Test
    func `cpu rate exactly at the threshold counts as active`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        // Binary-exact values so the boundary is genuinely exact: threshold 1/32, and
        // 0.9375 (15/16) CPU-seconds per 30s divides to exactly 1/32.
        let exact = IdleReleaseEvaluator.Config(enabled: true, idleThresholdSeconds: 90, cpuRateThreshold: 0.031_25, maxAssertionAgeHours: 1_000)
        _ = e.evaluate(assertions: [a], now: t0, config: exact, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        for step in 1 ... 10 {
            let cpu = 1.0 + Double(step) * 0.937_5
            let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(Double(step) * 30), config: exact, pidAlive: { _ in true }, cpuTime: { _ in cpu })
            #expect(out.isEmpty)
        }
    }

    @Test
    func `ttl expiring exactly now does not release yet`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0.addingTimeInterval(-5), ttl: 5)
        let out = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in nil })
        #expect(out.isEmpty, "expiry is strictly past the deadline")
    }

    @Test
    func `age exactly at the backstop does not release yet`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0.addingTimeInterval(-24 * 3_600), pid: -1)
        let out = e.evaluate(
            assertions: [a], now: t0,
            config: .init(enabled: true, idleThresholdSeconds: 90, maxAssertionAgeHours: 24),
            pidAlive: { _ in true }, cpuTime: { _ in nil },
        )
        #expect(out.isEmpty)
    }

    // MARK: Degenerate clocks and probes

    @Test
    func `a zero or negative sample gap neither crashes nor releases spuriously`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        // Same instant again (dt == 0): rate forced to 0, inside the window → nothing.
        let same = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(same.isEmpty)
        // Clock stepped backwards: idle duration goes negative → nothing.
        let backwards = e.evaluate(assertions: [a], now: t0.addingTimeInterval(-60), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(backwards.isEmpty)
    }

    @Test
    func `decreasing tree cpu (a busy child exited) reads as idle and eventually releases`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 100.0 })
        // Child exits: cumulative tree total DROPS. Negative rate is below the threshold.
        _ = e.evaluate(assertions: [a], now: t0.addingTimeInterval(30), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 40.0 })
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(30 + 91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 40.0 })
        #expect(out.map(\.reason) == [.cpuIdle])
    }

    @Test
    func `a cpu probe outage suspends the idle policy without releasing`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        // Probe fails for several sweeps — nothing released, no crash.
        for step in 1 ... 5 {
            let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(Double(step) * 30), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in nil })
            #expect(out.isEmpty)
        }
        // Probe recovers; the retained baseline spans the outage. Flat CPU across it means the
        // tree really was idle the whole time — releasing here is correct.
        let recovered = e.evaluate(assertions: [a], now: t0.addingTimeInterval(180), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(recovered.map(\.reason) == [.cpuIdle])
    }

    @Test
    func `two assertions sharing one pid evaluate sanely in a single sweep`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, key: "codex:a")
        let b = assertion(acquiredAt: t0, key: "codex:b")
        _ = e.evaluate(assertions: [a, b], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        let out = e.evaluate(assertions: [a, b], now: t0.addingTimeInterval(91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(Set(out.map(\.key)) == ["codex:a", "codex:b"], "both idle assertions release; neither corrupts the other's bookkeeping")
    }

    @Test
    func `forget keeping live pids retains their baselines`() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        e.forget(keeping: [100])
        // The baseline survived: the next sweep computes a rate (rather than re-seeding) and
        // releases the long-idle tree.
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(out.map(\.reason) == [.cpuIdle])
    }
}

/// Registry refresh semantics for duplicate acquires (resumed sessions arrive with a new pid).
@Suite("AssertionRegistry duplicate-acquire refresh")
struct RegistryRefreshTests {
    @Test
    func `duplicate acquire adopts the new pid and processName`() async {
        let r = AssertionRegistry()
        await r.acquire(Assertion(key: "claude-code:s1", tool: "claude-code", pid: 100, processName: "claude"))
        await r.acquire(Assertion(key: "claude-code:s1", tool: "claude-code", pid: 200, processName: "claude"))
        let stored = await r.snapshot().first
        #expect(stored?.pid == 200, "a resume reuses the session key under a new process")
    }

    @Test
    func `duplicate acquire without a resolved pid keeps the existing one`() async {
        let r = AssertionRegistry()
        await r.acquire(Assertion(key: "claude-code:s1", tool: "claude-code", pid: 100, processName: "claude"))
        await r.acquire(Assertion(key: "claude-code:s1", tool: "claude-code", pid: -1, processName: "claude-code"))
        let stored = await r.snapshot().first
        #expect(stored?.pid == 100, "an unresolved re-acquire must not discard a known good pid")
    }

    @Test
    func `duplicate acquire extends the ttl when one is given and keeps it otherwise`() async {
        let r = AssertionRegistry()
        await r.acquire(Assertion(key: "k", tool: "t", pid: 1, processName: "t", ttl: 60))
        let originalExpiry = await r.snapshot().first?.expiresAt

        await r.acquire(Assertion(key: "k", tool: "t", pid: 1, processName: "t"))
        #expect(await r.snapshot().first?.expiresAt == originalExpiry, "no incoming TTL keeps the deadline")

        await r.acquire(Assertion(key: "k", tool: "t", pid: 1, processName: "t", ttl: 3_600))
        let extended = await r.snapshot().first?.expiresAt
        #expect(extended != nil && extended! > originalExpiry!, "an incoming TTL re-arms the deadline")
    }

    @Test
    func `release all matching pid zero releases nothing`() async {
        let r = AssertionRegistry()
        await r.acquire(Assertion(key: "k", tool: "t", pid: 0, processName: "t"))
        #expect(await r.releaseAll(matchingPid: 0) == 0, "pid 0 is a sentinel, never a real exit event")
    }

    @Test
    func `blocking stream emits exactly true false true across a full cycle`() async {
        let r = AssertionRegistry()
        var iterator = r.blockingStateChanges.makeAsyncIterator()
        await r.acquire(Assertion(key: "a", tool: "t", pid: 1, processName: "t"))
        await r.release(key: "a")
        await r.acquire(Assertion(key: "b", tool: "t", pid: 1, processName: "t"))
        #expect(await iterator.next() == true)
        #expect(await iterator.next() == false)
        #expect(await iterator.next() == true)
    }
}
