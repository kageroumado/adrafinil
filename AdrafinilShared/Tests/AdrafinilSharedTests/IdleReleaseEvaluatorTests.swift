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
            config: .init(enabled: false, idleThresholdMinutes: 5, maxAssertionAgeHours: 24),
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

    // MARK: CPU-idle (the fixed seed-on-first-observation logic)

    @Test("first sweep seeds and never releases; flat CPU past the threshold then releases")
    func cpuIdleReleasesAfterThreshold() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        let cfg = IdleReleaseEvaluator.Config(enabled: true, idleThresholdMinutes: 5, maxAssertionAgeHours: 1000)

        let sweep1 = e.evaluate(assertions: [a], now: t0, config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(sweep1.isEmpty)   // seeded, not released

        let sweep2 = e.evaluate(assertions: [a], now: t0.addingTimeInterval(301), config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(reasons(sweep2) == [.cpuIdle])
    }

    @Test("CPU activity resets the idle clock (the regression the bug fix addresses)")
    func cpuActivityResetsClock() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        let cfg = IdleReleaseEvaluator.Config(enabled: true, idleThresholdMinutes: 5, maxAssertionAgeHours: 1000)

        _ = e.evaluate(assertions: [a], now: t0, config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })   // seed @ t0

        // Well past acquire+threshold, but CPU advanced → must NOT release (clock resets to now).
        let active = e.evaluate(assertions: [a], now: t0.addingTimeInterval(400), config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 2.0 })
        #expect(active.isEmpty)

        // Now flat for >threshold since the reset → releases.
        let idle = e.evaluate(assertions: [a], now: t0.addingTimeInterval(400 + 301), config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 2.0 })
        #expect(reasons(idle) == [.cpuIdle])
    }

    @Test("enabled=false suppresses CPU-idle but not the safety rules")
    func enabledFalseSuppressesCpuIdleOnly() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100)
        let cfg = IdleReleaseEvaluator.Config(enabled: false, idleThresholdMinutes: 5, maxAssertionAgeHours: 1000)

        // Flat CPU long past threshold, but disabled → no CPU-idle release.
        _ = e.evaluate(assertions: [a], now: t0, config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(10_000), config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        #expect(out.isEmpty)

        // Same disabled config, but a dead PID still releases (safety, not preference).
        let dead = e.evaluate(assertions: [a], now: t0, config: cfg, pidAlive: { _ in false }, cpuTime: { _ in 1.0 })
        #expect(reasons(dead) == [.deadProcess])
    }

    // MARK: Manual-hold idle exemption

    @Test("a manual hold is exempt from CPU-idle release")
    func manualHoldExemptFromCpuIdle() {
        let e = IdleReleaseEvaluator()
        let a = assertion(acquiredAt: t0, pid: 100, origin: .manual)
        let cfg = IdleReleaseEvaluator.Config(enabled: true, idleThresholdMinutes: 5, maxAssertionAgeHours: 1000)

        _ = e.evaluate(assertions: [a], now: t0, config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
        // Flat CPU well past the threshold — a hook assertion would be CPU-idle released here.
        let out = e.evaluate(assertions: [a], now: t0.addingTimeInterval(10_000), config: cfg, pidAlive: { _ in true }, cpuTime: { _ in 1.0 })
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
            config: .init(enabled: false, idleThresholdMinutes: 5, maxAssertionAgeHours: 1000),
            pidAlive: { _ in true },
            cpuTime: { _ in nil }
        )
        #expect(reasons(out) == [.ttlExpired])
    }
}
