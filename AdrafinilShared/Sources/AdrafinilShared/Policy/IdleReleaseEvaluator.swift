import Foundation

/// Decides which held assertions the idle monitor should release on a given sweep.
///
/// Holds the cross-sweep CPU bookkeeping needed for the "CPU-idle for N minutes" rule. The real
/// process probes (`kill(pid, 0)` for liveness, `proc_pidinfo` for CPU time) are injected as
/// closures, so the whole policy — including the safety backstop and the `enabled` gating — is
/// testable without live processes or wall-clock waits.
public final class IdleReleaseEvaluator {
    public struct Config: Equatable, Sendable {
        /// User-tunable CPU-idle policy. When false, only the safety rules (backstop, dead PID,
        /// TTL) apply — those are correctness, not preference, so nothing can pin sleep forever.
        public var enabled: Bool
        public var idleThresholdMinutes: Int
        /// Hard backstop: any assertion older than this is released regardless of PID or `enabled`.
        public var maxAssertionAgeHours: Double

        public init(enabled: Bool = true, idleThresholdMinutes: Int = 5, maxAssertionAgeHours: Double = 24) {
            self.enabled = enabled
            self.idleThresholdMinutes = idleThresholdMinutes
            self.maxAssertionAgeHours = maxAssertionAgeHours
        }
    }

    public struct Release: Equatable, Sendable {
        public enum Reason: String, Sendable {
            /// Leaked session: too old (unresolved PID + missed end hook).
            case maxAgeBackstop
            /// Owning process is gone.
            case deadProcess
            /// Owning process has been CPU-idle past the threshold.
            case cpuIdle
            /// The assertion's TTL elapsed.
            case ttlExpired
        }
        public let key: String
        public let reason: Reason

        public init(key: String, reason: Reason) {
            self.key = key
            self.reason = reason
        }
    }

    private var lastCpuTime: [pid_t: TimeInterval] = [:]
    private var lastCpuChange: [pid_t: Date] = [:]

    public init() {}

    /// Returns the assertions to release, each tagged with why. A single assertion can match more
    /// than one rule (e.g. CPU-idle *and* TTL-expired); callers should release by key and treat
    /// release as idempotent.
    ///
    /// - Parameters:
    ///   - pidAlive: liveness probe (`kill(pid, 0) == 0 || errno == EPERM` in production).
    ///   - cpuTime: cumulative user+system CPU seconds for a PID, or nil if unavailable.
    public func evaluate(
        assertions: [Assertion],
        now: Date,
        config: Config,
        pidAlive: (pid_t) -> Bool,
        cpuTime: (pid_t) -> TimeInterval?
    ) -> [Release] {
        var releases: [Release] = []
        let threshold = TimeInterval(config.idleThresholdMinutes * 60)
        let maxAge = config.maxAssertionAgeHours * 3600

        for a in assertions {
            // Safety backstop: a too-old assertion is a leak. Applies regardless of `enabled` or PID.
            if maxAge > 0, now.timeIntervalSince(a.acquiredAt) > maxAge {
                releases.append(Release(key: a.key, reason: .maxAgeBackstop))
                continue
            }
            // Dead process → release.
            if a.pid > 0, !pidAlive(a.pid) {
                releases.append(Release(key: a.key, reason: .deadProcess))
                continue
            }
            // CPU-idle check (user-tunable policy — only when enabled). Manual holds are exempt: an
            // explicit `adrafinil hold` for a background job has no user activity to measure and is
            // governed by its TTL instead. Dead-process release (above) still applies to a pid-bound
            // hold, so it releases the moment the watched job exits. The first observation of a
            // PID seeds the baseline (and never releases); subsequent sweeps reset the idle clock
            // when CPU advances and release only once it has been flat past the threshold. Seeding
            // on first sight is essential — defaulting `prev` to the current reading would make the
            // change check trivially false forever, collapsing the rule into "release any pid>0
            // assertion `threshold` after *acquisition*" regardless of activity.
            if config.enabled, a.origin != .manual, a.pid > 0, let cpu = cpuTime(a.pid) {
                if let prev = lastCpuTime[a.pid] {
                    if abs(cpu - prev) > 0.01 {
                        lastCpuChange[a.pid] = now
                        lastCpuTime[a.pid] = cpu
                    } else if now.timeIntervalSince(lastCpuChange[a.pid] ?? a.acquiredAt) > threshold {
                        releases.append(Release(key: a.key, reason: .cpuIdle))
                    }
                } else {
                    lastCpuTime[a.pid] = cpu
                    lastCpuChange[a.pid] = now
                }
            }
            // TTL check.
            if let exp = a.expiresAt, exp < now {
                releases.append(Release(key: a.key, reason: .ttlExpired))
            }
        }
        return releases
    }
}
