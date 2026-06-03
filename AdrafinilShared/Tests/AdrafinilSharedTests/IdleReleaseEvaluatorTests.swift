import Testing
import Foundation
@testable import AdrafinilShared

@Suite("IdleReleaseEvaluator")
struct IdleReleaseEvaluatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func assertion(acquiredAt: Date, key: String = "k", pid: pid_t = 100, ttl: TimeInterval? = nil, origin: AssertionOrigin = .hook) -> Assertion {
        Assertion(key: key, tool: "claude-code", pid: pid, processName: "claude", acquiredAt: acquiredAt, ttl: ttl, origin: origin)
    }

    private func keys(_ rs: [IdleReleaseEvaluator.Release]) -> [String] { rs.map(\.key) }
    private func reasons(_ rs: [IdleReleaseEvaluator.Release]) -> [IdleReleaseEvaluator.Release.Reason] { rs.map(\.reason) }

    // MARK: Safety backstop

    @Test("max-age backstop releases an old assertion regardless of PID or enabled")
    func backstopReleasesOldAssertion() {
        let e = IdleReleaseEvaluator()
        let old = assertion(acquiredAt: t0.addingTimeInterval(-25 * 3600), pid: 100)
        let out = e.evaluate(
            assertions: [old],
            now: t0,
            config: .init(enabled: false, idleThresholdSeconds: 90, maxAssertionAgeHours: 24),
            pidAlive: { _ in true },
            cpuTime: { _ in 1.0 }
        )
        #expect(reasons(out) == [.maxAgeBackstop])
    }

    @Test("backstop applies even to unresolved (pid <= 0) assertions")
    func backstopReleasesUnresolvedPid() {
        let e = IdleReleaseEvaluator()
        let old = assertion(acquiredAt: t0.addingTimeInterval(-25 * 3600), pid: -1)
        let out = e.evaluate(assertions: [old], now: t0, config: .init(), pidAlive: { _ in true }, cpuTime: { _ in nil })
        #expect(reasons(out) == [.maxAgeBackstop])
    }

    @Test("a too-young assertion with no resolved PID survives (until the backstop)")
    func unresolvedYoungSurvives() {
        let e = IdleReleaseEvaluator()
        let young = assertion(acquiredAt: t0, pid: -1)
        let out = e.evaluate(assertions: [young], now: t0.addingTimeInterval(60), config: .init(), pidAlive: { _ in true }, cpuTime: { _ in nil })
        #expect(out.isEmpty)
    }

    // MARK: Dead process

    @Test("a dead owning process is released")
    func deadProcessReleased() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        let out = e.evaluate(assertions: [a], now: t0, config: .init(), pidAlive: { _ in false }, cpuTime: { _ in 1.0 })
        #expect(reasons(out) == [.deadProcess])
    }

    // MARK: CPU-rate idle (idle = tree CPU rate below the threshold, sustained)

    /// Default config: 90s idle window, 3% rate threshold. CPU values are cumulative seconds, so a
    /// rate is the per-second slope between two samples (30s apart ≈ a real sweep).
    private func cfg(idle: TimeInterval = 90, rate: Double = 0.03) -> IdleReleaseEvaluator.Config {
        .init(enabled: true, idleThresholdSeconds: idle, cpuRateThreshold: rate, maxAssertionAgeHours: 1000)
    }

    @Test("first sweep seeds and never releases; idle tree past the window then releases")
    func cpuIdleReleasesAfterThreshold() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)

        let sweep1 = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(sweep1.isEmpty)   // seeded, not released

        // Flat CPU (rate 0) for >90s → released.
        let sweep2 = e.evaluate(assertions: [a], now: t0.addingTimeInterval(91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(reasons(sweep2) == [.cpuIdle])
    }

    /// The core of the fix: an idle `claude` TUI still burns ~1% CPU. A slow, steady drift well below
    /// the 3% rate line must read as idle and release — the old absolute-change rule never did.
    @Test("slow sub-threshold CPU drift still counts as idle and releases")
    func slowDriftIsIdle() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        // ~1% rate: +0.3 CPU-seconds every 30s = 0.01/s, well under 0.03.
        var cpu = 1.0
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in cpu })
        var out: [IdleReleaseEvaluator.Release] = []
        for step in 1...4 {                       // 30, 60, 90, 120s
            cpu += 0.3
            out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(Double(step) * 30), config: cfg(),
                             pidAlive: { _ in true }, cpuTime: { _ in cpu })
        }
        #expect(reasons(out) == [.cpuIdle])       // by 120s the drift never cleared the rate line
    }

    @Test("a busy tree (rate above threshold) stamps activity and is never released")
    func busyTreeStaysAwake() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        // +2.0 CPU-seconds every 30s = 0.067/s, above the 3% line (e.g. a busy build child).
        var cpu = 1.0
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in cpu })
        for step in 1...10 {                       // 300s of sustained work
            cpu += 2.0
            let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(Double(step) * 30), config: cfg(),
                                 pidAlive: { _ in true }, cpuTime: { _ in cpu })
            #expect(out.isEmpty)
        }
    }

    @Test("a burst of activity resets the idle clock")
    func activityResetsClock() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })     // seed
        // Active burst at +30s (rate 0.033) → resets lastActive to t0+30.
        let active = e.evaluate(assertions: [a], now: t0.addingTimeInterval(30), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 2.0 })
        #expect(active.isEmpty)
        // Flat for >90s since the reset → releases.
        let idle = e.evaluate(assertions: [a], now: t0.addingTimeInterval(30 + 91), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 2.0 })
        #expect(reasons(idle) == [.cpuIdle])
    }

    @Test("enabled=false suppresses CPU-idle but not the safety rules")
    func enabledFalseSuppressesCpuIdleOnly() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        let disabled = IdleReleaseEvaluator.Config(enabled: false, idleThresholdSeconds: 90, maxAssertionAgeHours: 1000)

        // Flat CPU long past the window, but disabled → no CPU-idle release.
        _ = e.evaluate(assertions: [a], now: t0, config: disabled, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(10_000), config: disabled, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(out.isEmpty)

        // Same disabled config, but a dead PID still releases (safety, not preference).
        let dead = e.evaluate(assertions: [a], now: t0, config: disabled, pidAlive: { _ in false }, cpuTime: { _ in 1.0 })
        #expect(reasons(dead) == [.deadProcess])
    }

    // MARK: Wake-assertion signal (the thinking-gap fix)

    @Test("an idle tree that still holds a wake assertion is NOT released (thinking)")
    func wakeAssertionKeepsIdleTreeAlive() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        // Flat CPU (a thinking agent: server-side compute, near-idle client) but the tree holds a
        // wake assertion (its caffeinate child) the whole time → must never release.
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true },
                       cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
        for step in 1...8 {                        // 240s of idle CPU but asserting
            let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(Double(step) * 30), config: cfg(),
                                 pidAlive: { _ in true }, cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
            #expect(out.isEmpty)
        }
    }

    @Test("once the wake assertion drops, an idle tree releases after the window")
    func releasesAfterWakeAssertionDrops() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        // Asserting + idle CPU for a while → held.
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true },
                       cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
        let held = e.evaluate(assertions: [a], now: t0.addingTimeInterval(120), config: cfg(), pidAlive: { _ in true },
                              cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
        #expect(held.isEmpty)
        // Turn ends / interrupt → caffeinate gone (no assertion), CPU still idle. The idle clock
        // restarts from the last active stamp (t0+120); >90s later → released.
        _ = e.evaluate(assertions: [a], now: t0.addingTimeInterval(150), config: cfg(), pidAlive: { _ in true },
                       cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in false })
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(120 + 91), config: cfg(), pidAlive: { _ in true },
                             cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in false })
        #expect(reasons(out) == [.cpuIdle])
    }

    @Test("a manual hold ignores the wake-assertion signal (TTL still governs)")
    func manualHoldIgnoresWakeAssertion() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100, origin: .manual)
        // Manual holds skip the whole CPU/assertion branch — asserting or not, only TTL/dead-pid apply.
        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true },
                       cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(10_000), config: cfg(), pidAlive: { _ in true },
                             cpuTime: { _ in 1.0 }, treeHoldsWakeAssertion: { _ in true })
        #expect(out.isEmpty)
    }

    // MARK: Manual-hold idle exemption

    @Test("a manual hold is exempt from CPU-idle release")
    func manualHoldExemptFromCpuIdle() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100, origin: .manual)

        _ = e.evaluate(assertions: [a], now: t0, config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        // Flat CPU well past the window — a hook assertion would be CPU-idle released here.
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(10_000), config: cfg(), pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(out.isEmpty)
    }

    @Test("a pid-bound manual hold still releases when its process dies")
    func manualHoldReleasesOnDeadPid() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100, origin: .manual)
        let out = e.evaluate(assertions: [a], now: t0, config: .init(), pidAlive: { _ in false }, cpuTime: { _ in 1.0 })
        #expect(reasons(out) == [.deadProcess])
    }

    @Test("a manual hold still expires on TTL")
    func manualHoldExpiresOnTTL() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0.addingTimeInterval(-10), pid: -1, ttl: 5, origin: .manual)
        let out = e.evaluate(assertions: [a], now: t0, config: .init(), pidAlive: { _ in true }, cpuTime: { _ in nil })
        #expect(reasons(out) == [.ttlExpired])
    }

    // MARK: TTL

    @Test("an expired TTL releases regardless of enabled")
    func ttlExpiredReleased() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0.addingTimeInterval(-10), pid: 100, ttl: 5)   // expired 5s ago
        let out = e.evaluate(
            assertions: [a],
            now: t0,
            config: .init(enabled: false, idleThresholdSeconds: 90, maxAssertionAgeHours: 1000),
            pidAlive: { _ in true },
            cpuTime: { _ in nil }
        )
        #expect(reasons(out) == [.ttlExpired])
    }
}
