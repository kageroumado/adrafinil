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
        /// Release once the owning process tree has stayed below `cpuRateThreshold` for this long.
        public var idleThresholdSeconds: TimeInterval
        /// CPU usage rate (fraction of one core; 0.03 = 3%) below which the process tree counts as
        /// idle. An interrupted `claude` session idles around 1% (TUI + MCP heartbeats), while real
        /// work — model streaming, per-token re-render, or a busy tool child — runs far higher, so a
        /// few-percent line separates the two. Measured against the *tree* so a long tool call (a busy
        /// build child) keeps it above the line even while the agent process itself waits.
        public var cpuRateThreshold: Double
        /// Hard backstop: any assertion older than this is released regardless of PID or `enabled`.
        public var maxAssertionAgeHours: Double

        public init(enabled: Bool = true, idleThresholdSeconds: TimeInterval = 90,
                    cpuRateThreshold: Double = 0.03, maxAssertionAgeHours: Double = 24) {
            self.enabled = enabled
            self.idleThresholdSeconds = idleThresholdSeconds
            self.cpuRateThreshold = cpuRateThreshold
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

    /// Cross-sweep CPU bookkeeping, per PID: the last cumulative CPU reading, when it was sampled
    /// (to turn two readings into a rate), and the last time the tree was observed *active* (rate at
    /// or above the threshold). Idle duration is measured from `lastActive`.
    private var lastCpuTime: [pid_t: TimeInterval] = [:]
    private var lastSampleAt: [pid_t: Date] = [:]
    private var lastActiveAt: [pid_t: Date] = [:]

    public init() {}

    /// Returns the assertions to release, each tagged with why. A single assertion can match more
    /// than one rule (e.g. CPU-idle *and* TTL-expired); callers should release by key and treat
    /// release as idempotent.
    ///
    /// - Parameters:
    ///   - pidAlive: liveness probe (`kill(pid, 0) == 0 || errno == EPERM` in production).
    ///   - cpuTime: cumulative user+system CPU seconds for the PID's whole process *tree*, or nil if
    ///     unavailable. Tree (not just the agent process) so a long tool call — where the agent waits
    ///     while a busy child does the work — still reads as active.
    public func evaluate(
        assertions: [Assertion],
        now: Date,
        config: Config,
        pidAlive: (pid_t) -> Bool,
        cpuTime: (pid_t) -> TimeInterval?
    ) -> [Release] {
        var releases: [Release] = []
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
            // CPU-rate idle check (user-tunable policy — only when enabled). Manual holds are exempt:
            // an explicit `adrafinil hold` for a background job has no user activity to measure and is
            // governed by its TTL instead. Dead-process release (above) still applies to a pid-bound
            // hold, so it releases the moment the watched job exits.
            //
            // Two readings make a rate (Δcpu / Δt). The first sighting of a PID only seeds the
            // baseline (and marks it active, so a freshly-seen process is never released on the same
            // sweep). On each later sweep we recompute the rate: at or above `cpuRateThreshold` the
            // tree is working, so we stamp `lastActiveAt`; below it, we release once the tree has been
            // continuously idle (no active stamp) for `idleThresholdSeconds`. Rate, not absolute
            // change, because an idle `claude` TUI still burns ~1% CPU — an absolute-delta rule treats
            // that as "active" forever and never releases.
            if config.enabled, a.origin != .manual, a.pid > 0, let cpu = cpuTime(a.pid) {
                if let prev = lastCpuTime[a.pid], let prevAt = lastSampleAt[a.pid] {
                    let dt = now.timeIntervalSince(prevAt)
                    let rate = dt > 0 ? (cpu - prev) / dt : 0
                    lastCpuTime[a.pid] = cpu
                    lastSampleAt[a.pid] = now
                    if rate >= config.cpuRateThreshold {
                        lastActiveAt[a.pid] = now
                    } else if now.timeIntervalSince(lastActiveAt[a.pid] ?? a.acquiredAt) > config.idleThresholdSeconds {
                        releases.append(Release(key: a.key, reason: .cpuIdle))
                    }
                } else {
                    lastCpuTime[a.pid] = cpu
                    lastSampleAt[a.pid] = now
                    lastActiveAt[a.pid] = now
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
