import AdrafinilShared
import Darwin
import Foundation
import OSLog

/// Releases assertions whose owning process is dead or has been CPU-idle for a configurable window.
@MainActor
final class IdleMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "IdleMonitor")

    /// When false, idle and CPU-based release is suppressed (TTL expiry, dead-PID release, and
    /// the max-age backstop still apply — those are safety, not the user-tunable idle policy).
    var enabled: Bool = true
    var idleThresholdSeconds: TimeInterval = 90

    /// Hard safety backstop: any assertion older than this is released regardless of PID or the
    /// idle policy. Catches genuine leaks — an assertion whose owning process we never resolved
    /// (`pid <= 0`, so neither the exit-watcher nor the dead-PID check can fire) and whose agent
    /// never sent its end hook. Generous so it never cuts a real session short; a leak just
    /// outlives a long task, not forever.
    var maxAssertionAgeHours: Double = 24

    var assertionSource: (() async -> [Assertion])?
    var onIdleRelease: (([String]) -> Void)?

    private var timer: Timer?

    /// Process parent→children map captured once at the start of each sweep and read by the tree
    /// walks (`cpuTimeTree`, `treeContains`). Sweep-scoped: rebuilt every sweep, never read between.
    private var sweepChildMap: [pid_t: [pid_t]] = [:]

    /// The release decision (backstop / dead-PID / CPU-idle / TTL) lives in AdrafinilShared, where
    /// it is unit-tested with simulated process probes. The evaluator holds the cross-sweep CPU
    /// bookkeeping; this monitor supplies the real `kill`/`proc_pidinfo` probes and the timer.
    private let evaluator = IdleReleaseEvaluator()

    /// Sweep every 30s: two samples this close turn into a meaningful CPU rate, and it bounds
    /// Whether any assertion is currently held. The idle/death sweep only does anything while we're
    /// keeping the Mac awake (with zero assertions there is nothing to release), so this gates the
    /// timer itself: no 30s wakeups while the daemon is idle — exactly when the Mac would otherwise be
    /// asleep and a timer would needlessly spin the CPU back up. Mirrors `ThermalMonitor.isBlocking`.
    var isBlocking: Bool = false {
        didSet {
            guard isBlocking != oldValue else { return }
            if isBlocking { startPolling() } else { stopPolling() }
        }
    }

    /// interrupt-detection latency to roughly the idle threshold rather than a multiple of it.
    func start() {
        // No polling until something is blocking — `isBlocking`'s didSet arms/disarms the timer.
        if isBlocking { startPolling() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sweep() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func sweep() async {
        guard let assertions = await assertionSource?() else { return }
        let config = IdleReleaseEvaluator.Config(
            enabled: enabled,
            idleThresholdSeconds: idleThresholdSeconds,
            maxAssertionAgeHours: maxAssertionAgeHours,
        )
        // One process-table snapshot per sweep, shared by every tree walk below (CPU sum + wake
        // assertion). Built from KERN_PROC_ALL because proc_listchildpids is unreliable here.
        sweepChildMap = ProcessResolver.childMap()
        // One system-wide read per sweep: the PIDs currently asserting "keep the system awake".
        // Scoped per-assertion to the owning agent's tree below (a global check would always be true).
        let wakePIDs = PowerAssertionReader.pidsPreventingSystemSleep()
        let releases = evaluator.evaluate(
            assertions: assertions,
            now: Date(),
            config: config,
            pidAlive: { self.pidExists($0) },
            cpuTime: { self.cpuTimeTree(rootPID: $0) },
            treeHoldsWakeAssertion: { self.treeContains(rootPID: $0, anyOf: wakePIDs) },
        )
        // Prune bookkeeping for PIDs that no longer back a live assertion — bound the per-PID maps
        // on this always-on daemon and stop a recycled PID inheriting a vanished process's baseline.
        evaluator.forget(keeping: Set(assertions.map(\.pid).filter { $0 > 0 }))
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
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Cumulative CPU seconds for `rootPID` plus every descendant, over this sweep's process snapshot.
    /// Delegates to `ProcessResolver.treeCPUTime` so the sniffer's activity gate and this idle check
    /// sum the tree identically.
    private func cpuTimeTree(rootPID: pid_t) -> TimeInterval? {
        ProcessResolver.treeCPUTime(rootPID: rootPID, childMap: sweepChildMap)
    }

    /// Whether `rootPID` or any descendant is in `pids`. Walks the same tree as the CPU sum, so a wake
    /// assertion held by a *child* counts for the agent — Claude Code's `caffeinate` is a child of
    /// `claude`, not `claude` itself. Short-circuits to false when nothing is asserting (the common
    /// case), avoiding the process walk entirely.
    private func treeContains(rootPID: pid_t, anyOf pids: Set<pid_t>) -> Bool {
        guard !pids.isEmpty else { return false }
        if pids.contains(rootPID) { return true }
        var seen: Set<pid_t> = [rootPID]
        var stack = childPIDs(of: rootPID)
        while let pid = stack.popLast() {
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)
            if pids.contains(pid) { return true }
            stack.append(contentsOf: childPIDs(of: pid))
        }
        return false
    }

    /// Direct children of `pid` from this sweep's `KERN_PROC_ALL` snapshot. (Was `proc_listchildpids`,
    /// which returns garbage counts on current macOS — the bug that left the tree walk seeing no
    /// children, so a busy child's CPU and a child's wake assertion both went unnoticed.)
    private func childPIDs(of pid: pid_t) -> [pid_t] {
        sweepChildMap[pid] ?? []
    }
}
