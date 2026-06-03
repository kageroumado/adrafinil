import Foundation

/// Decides whether a process tree is *currently working*, from successive CPU-time samples.
///
/// The daemon's sniffer uses this to gate auto-acquire for shared, long-lived agent daemons (a
/// Hermes gateway or desktop dashboard) where mere presence doesn't mean activity: such a process
/// sits at ~0.3% CPU between turns and spikes to tens of percent during one. Acquiring on presence
/// would pin sleep around the clock and, paired with idle-release, flap on/off forever. Gating the
/// acquire on a real CPU rate means an idle daemon is never held, while a busy one is picked up
/// within a sweep or two — and once the turn ends, the idle-release net (sharing
/// `IdleReleaseEvaluator.defaultCPURateThreshold`) tears the hold down.
///
/// A rate needs two samples, so the first sighting of a PID only seeds the baseline and reports
/// inactive. Bookkeeping is keyed by PID; call `forget(keeping:)` each sweep to drop exited
/// processes (PIDs are recycled, so stale state must not linger).
public final class ProcessActivityGate {
    private var lastSample: [pid_t: (cpu: TimeInterval, at: Date)] = [:]

    public init() {}

    /// Whether `pid`'s tree is busy: its CPU rate since the previous sample is at or above
    /// `rateThreshold` (a fraction of one core). Records `treeCPU`/`now` as the new baseline.
    /// Returns false on the first sighting (no prior sample) and on a non-positive time delta.
    public func isActive(
        pid: pid_t,
        treeCPU: TimeInterval,
        now: Date,
        rateThreshold: Double = IdleReleaseEvaluator.defaultCPURateThreshold,
    ) -> Bool {
        defer { lastSample[pid] = (treeCPU, now) }
        guard let prev = lastSample[pid] else { return false }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0 else { return false }
        return (treeCPU - prev.cpu) / dt >= rateThreshold
    }

    /// Drop bookkeeping for any PID not in `livePids`, so a recycled PID starts from a fresh
    /// baseline rather than inheriting a vanished process's CPU total.
    public func forget(keeping livePids: Set<pid_t>) {
        lastSample = lastSample.filter { livePids.contains($0.key) }
    }
}
