import Foundation
import AdrafinilShared
import Darwin
import OSLog

/// Releases assertions whose owning process is dead or has been CPU-idle for a configurable window.
@MainActor
final class IdleMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "IdleMonitor")

    /// When false, idle and CPU-based release is suppressed (TTL expiry, dead-PID release, and
    /// the max-age backstop still apply — those are safety, not the user-tunable idle policy).
    var enabled: Bool = true
    var idleThresholdMinutes: Int = 5

    /// Hard safety backstop: any assertion older than this is released regardless of PID or the
    /// idle policy. Catches genuine leaks — an assertion whose owning process we never resolved
    /// (`pid <= 0`, so neither the exit-watcher nor the dead-PID check can fire) and whose agent
    /// never sent its end hook. Generous so it never cuts a real session short; a leak just
    /// outlives a long task, not forever.
    var maxAssertionAgeHours: Double = 24

    var assertionSource: (() async -> [Assertion])?
    var onIdleRelease: (([String]) -> Void)?

    private var timer: Timer?

    /// The release decision (backstop / dead-PID / CPU-idle / TTL) lives in AdrafinilShared, where
    /// it is unit-tested with simulated process probes. The evaluator holds the cross-sweep CPU
    /// bookkeeping; this monitor supplies the real `kill`/`proc_pidinfo` probes and the timer.
    private let evaluator = IdleReleaseEvaluator()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sweep() }
        }
    }

    private func sweep() async {
        guard let assertions = await assertionSource?() else { return }
        let config = IdleReleaseEvaluator.Config(
            enabled: enabled,
            idleThresholdMinutes: idleThresholdMinutes,
            maxAssertionAgeHours: maxAssertionAgeHours
        )
        let releases = evaluator.evaluate(
            assertions: assertions,
            now: Date(),
            config: config,
            pidAlive: { self.pidExists($0) },
            cpuTime: { self.cpuTime(pid: $0) }
        )
        guard !releases.isEmpty else { return }

        for r in releases where r.reason == .maxAgeBackstop {
            log.warning("Backstop-releasing assertion '\(r.key, privacy: .public)' — exceeds max-age cap (likely a leaked session with an unresolved PID and a missed end hook)")
        }
        let keys = Array(Set(releases.map(\.key)))
        log.info("Idle-releasing \(keys.count, privacy: .public) assertions")
        onIdleRelease?(keys)
    }

    private func pidExists(_ pid: pid_t) -> Bool {
        // kill(pid, 0) returns 0 if the process exists and we have permission.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func cpuTime(pid: pid_t) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return nil }
        let user = TimeInterval(info.pti_total_user) / 1_000_000_000
        let sys = TimeInterval(info.pti_total_system) / 1_000_000_000
        return user + sys
    }
}
