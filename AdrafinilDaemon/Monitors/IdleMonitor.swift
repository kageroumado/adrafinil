import Foundation
import AdrafinilShared
import Darwin
import OSLog

/// Releases assertions whose owning process is dead or has been CPU-idle for a configurable window.
@MainActor
final class IdleMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "IdleMonitor")

    /// When false, idle and CPU-based release is suppressed (TTL expiry and dead-PID
    /// release still apply — those are safety, not the user-tunable idle policy).
    var enabled: Bool = true
    var idleThresholdMinutes: Int = 5
    var assertionSource: (() async -> [Assertion])?
    var onIdleRelease: (([String]) -> Void)?

    private var timer: Timer?
    private var lastCpuTime: [pid_t: TimeInterval] = [:]
    private var lastCpuChange: [pid_t: Date] = [:]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sweep() }
        }
    }

    private func sweep() async {
        guard let assertions = await assertionSource?() else { return }
        var toRelease: [String] = []
        let now = Date()
        let threshold = TimeInterval(idleThresholdMinutes * 60)

        for a in assertions {
            // Dead process → release.
            if a.pid > 0 && !pidExists(a.pid) {
                toRelease.append(a.key)
                continue
            }
            // CPU idle check (user-tunable policy — only when enabled).
            if enabled, a.pid > 0, let cpu = cpuTime(pid: a.pid) {
                let prev = lastCpuTime[a.pid] ?? cpu
                if abs(cpu - prev) > 0.01 {
                    lastCpuChange[a.pid] = now
                    lastCpuTime[a.pid] = cpu
                } else {
                    let lastChange = lastCpuChange[a.pid] ?? a.acquiredAt
                    if now.timeIntervalSince(lastChange) > threshold {
                        toRelease.append(a.key)
                    }
                }
            }
            // TTL check.
            if let exp = a.expiresAt, exp < now {
                toRelease.append(a.key)
            }
        }

        if !toRelease.isEmpty {
            log.info("Idle-releasing \(toRelease.count) assertions")
            onIdleRelease?(toRelease)
        }
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
