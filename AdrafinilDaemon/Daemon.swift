import Foundation
import AdrafinilShared
import OSLog

@MainActor
final class Daemon {
    let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "Daemon")

    let registry = AssertionRegistry()
    let helperClient = HelperClient()
    let stateStore = StateStore()
    let eventLog = EventLog()

    var settings: AdrafinilSettings = AdrafinilSettings.load()

    let lidMonitor = LidStateMonitor()
    let processWatcher = ProcessWatcher()
    let idleMonitor = IdleMonitor()
    let thermalMonitor = ThermalMonitor()
    let chimePlayer = ChimePlayer()

    var appXPCServer: AppXPCServer!
    var cliServer: CLISocketServer!

    private var sweepTimer: Timer?
    private var blockingObserver: Task<Void, Never>?

    // "While you were away" tracking (SPEC §6.4 / §7.3).
    private var lidClosedAt: Date?
    private var heldAtClose: [(tool: String, displayName: String, acquiredAt: Date)] = []
    private var peakTempWhileClosed: Double?
    private var thermalCutoutWhileClosed = false
    private var pendingAwaySummary: AwaySummary?

    func start() async {
        log.info("Adrafinil daemon starting")

        // Restore previous assertions (in case of daemon restart while agents were live).
        if let restored = stateStore.load() {
            await registry.replaceAll(with: restored)
            log.info("Restored \(restored.count) assertions from state file")
        }

        observeBlockingState()
        wireMonitors()

        appXPCServer = AppXPCServer(daemon: self)
        appXPCServer.start()

        cliServer = CLISocketServer(daemon: self)
        cliServer.start()

        // Initial sync: seed the monitors with the current state (the registry's edge callback
        // only fires on *changes*, so restored state must be applied explicitly), re-arm the
        // exit-watch for any restored assertions, and apply the blocking state to the helper.
        let blocking = await registry.isBlocking
        thermalMonitor.isBlocking = blocking
        thermalMonitor.lidClosed = lidMonitor.isLidClosed
        for a in await registry.snapshot() where a.pid > 0 { processWatcher.watch(pid: a.pid) }
        await syncHelperToRegistry()

        startSweep()
    }

    // MARK: - Public API used by IPC servers

    func handleAcquire(_ assertion: Assertion) async {
        let isNew = await registry.acquire(assertion)
        // Watch the owning process so the assertion is force-released if the agent dies without
        // firing its end hook (SPEC §5.4 / §5.5). watch() is idempotent. pid <= 0 means the CLI
        // could not identify a real agent process and asked us not to watch.
        if assertion.pid > 0 { processWatcher.watch(pid: assertion.pid) }
        // Duplicate acquires are no-ops for the count (SPEC §5.6) — don't log/persist them.
        if isNew { await persistAndSync(event: .acquired) }
    }

    @discardableResult
    func handleRelease(key: String) async -> Bool {
        let existed = await registry.release(key: key)
        if existed {
            await persistAndSync(event: .released)
        } else {
            // Unknown key is a warning, not an error (SPEC §5.6).
            log.warning("Release for unknown key '\(key)' — no-op")
        }
        return existed
    }

    func handleForceReleaseAll() async {
        await registry.removeAll()
        await persistAndSync(event: .released)
    }

    func currentStatus() async -> DaemonStatus {
        let snapshot = await registry.snapshot()
        return DaemonStatus(
            isBlocking: !snapshot.isEmpty,
            assertions: snapshot,
            lidClosed: lidMonitor.isLidClosed,
            helperConnected: helperClient.isConnected,
            cpuTemperatureCelsius: thermalMonitor.lastReadingCelsius,
            lastEvent: eventLog.last,
            lastEventAt: eventLog.lastAt
        )
    }

    /// Returns and clears the pending "while you were away" summary (consume-once).
    func consumeAwaySummary() -> AwaySummary? {
        defer { pendingAwaySummary = nil }
        return pendingAwaySummary
    }

    func reloadSettings() {
        settings = AdrafinilSettings.load()
        idleMonitor.idleThresholdMinutes = settings.idleReleaseMinutes
        idleMonitor.enabled = settings.idleReleaseEnabled
        thermalMonitor.thresholdCelsius = settings.thermalThresholdCelsius
        thermalMonitor.enabled = settings.thermalCutoutEnabled
    }

    // MARK: - Internal

    private func observeBlockingState() {
        // Single long-lived consumer. Applying transitions serially (awaiting each helper
        // round-trip before handling the next) guarantees the helper reflects the latest
        // blocking state — unlike spawning a Task per edge, which could apply out of order.
        blockingObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await blocking in self.registry.blockingStateChanges {
                self.thermalMonitor.isBlocking = blocking
                await self.helperClient.setBlocked(blocking)
            }
        }
    }

    private func wireMonitors() {
        lidMonitor.onChange = { [weak self] closed in
            guard let self else { return }
            Task { @MainActor in
                self.eventLog.append(closed ? .lidClosed : .lidOpened)
                self.thermalMonitor.lidClosed = closed
                if closed {
                    if await self.registry.isBlocking {
                        if self.settings.soundOnLidClose {
                            self.chimePlayer.playLidCloseChime(volume: self.settings.soundVolume,
                                                               chimeName: self.settings.chimeName)
                        }
                        self.beginAwayTracking(snapshot: await self.registry.snapshot())
                    }
                } else {
                    await self.finishAwayTracking()
                }
            }
        }

        processWatcher.onProcessExit = { [weak self] pid in
            guard let self else { return }
            Task { @MainActor in
                let removed = await self.registry.releaseAll(matchingPid: pid)
                if removed > 0 {
                    self.log.info("Released \(removed) assertion(s) after PID \(pid) exited")
                    await self.persistAndSync(event: .released)
                }
            }
        }
        processWatcher.start()

        idleMonitor.onIdleRelease = { [weak self] keys in
            guard let self else { return }
            Task { @MainActor in
                var released = 0
                for key in keys where await self.registry.release(key: key) { released += 1 }
                if released > 0 { await self.persistAndSync(event: .idleRelease) }
            }
        }
        idleMonitor.assertionSource = { [weak self] in
            await self?.registry.snapshot() ?? []
        }
        idleMonitor.idleThresholdMinutes = settings.idleReleaseMinutes
        idleMonitor.enabled = settings.idleReleaseEnabled
        idleMonitor.start()

        thermalMonitor.thresholdCelsius = settings.thermalThresholdCelsius
        thermalMonitor.enabled = settings.thermalCutoutEnabled
        thermalMonitor.onReading = { [weak self] temp in
            MainActor.assumeIsolated {
                guard let self, self.lidClosedAt != nil else { return }
                self.peakTempWhileClosed = max(self.peakTempWhileClosed ?? temp, temp)
            }
        }
        thermalMonitor.onCutout = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.log.warning("Thermal cutout triggered — releasing all assertions")
                if self.lidClosedAt != nil { self.thermalCutoutWhileClosed = true }
                await self.registry.removeAll()
                await self.persistAndSync(event: .thermalCutout)
            }
        }
        thermalMonitor.start()
    }

    /// Periodic safety-net sweep (SPEC §5.4): re-arms exit-watching for every held assertion
    /// (covers assertions restored after a daemon restart that never went through `handleAcquire`)
    /// and, when the user has opted in, auto-acquires for running known-agent processes that have
    /// no assertion yet.
    private func startSweep() {
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.processSweep() }
        }
    }

    private func processSweep() async {
        guard settings.processSniffingEnabled else { return }
        let snapshot = await registry.snapshot()
        for a in snapshot where a.pid > 0 { processWatcher.watch(pid: a.pid) }

        guard settings.autoAcquireForKnownAgents else { return }
        let watchedPids = Set(snapshot.map(\.pid))
        for proc in ProcessResolver.runningProcesses() {
            guard let kind = AgentKind.byBinaryName[proc.name], !watchedPids.contains(proc.pid) else { continue }
            let assertion = Assertion(
                key: "sniffed:\(kind.rawValue):\(proc.pid)",
                tool: kind.rawValue,
                reason: "auto (process sniffing)",
                pid: proc.pid,
                processName: proc.name
            )
            log.info("Auto-acquiring for sniffed agent \(kind.rawValue) (pid \(proc.pid))")
            await handleAcquire(assertion)
        }
    }

    private func beginAwayTracking(snapshot: [Assertion]) {
        lidClosedAt = Date()
        heldAtClose = snapshot.map {
            ($0.tool, AgentKind(rawValue: $0.tool)?.displayName ?? $0.tool, $0.acquiredAt)
        }
        peakTempWhileClosed = thermalMonitor.lastReadingCelsius
        thermalCutoutWhileClosed = false
    }

    private func finishAwayTracking() async {
        guard let closedAt = lidClosedAt, !heldAtClose.isEmpty else {
            lidClosedAt = nil
            heldAtClose = []
            return
        }
        let openedAt = Date()
        let activeTools = Set(await registry.snapshot().map(\.tool))
        var finished: [FinishedAgentSummary] = []
        var stillActive: [FinishedAgentSummary] = []
        for held in heldAtClose {
            let item = FinishedAgentSummary(
                tool: held.tool,
                displayName: held.displayName,
                duration: openedAt.timeIntervalSince(held.acquiredAt)
            )
            if activeTools.contains(held.tool) { stillActive.append(item) } else { finished.append(item) }
        }
        pendingAwaySummary = AwaySummary(
            closedAt: closedAt,
            openedAt: openedAt,
            finished: finished,
            stillActive: stillActive,
            peakTemperatureCelsius: peakTempWhileClosed,
            thermalCutout: thermalCutoutWhileClosed
        )
        log.info("Away summary: \(finished.count) finished, \(stillActive.count) still active")
        lidClosedAt = nil
        heldAtClose = []
    }

    private func persistAndSync(event: DaemonEvent) async {
        eventLog.append(event)
        let snapshot = await registry.snapshot()
        stateStore.save(snapshot)
        // Helper sync is edge-triggered via the registry's blockingStateChanges stream —
        // no redundant XPC round-trip on every acquire/release here.
    }

    private func syncHelperToRegistry() async {
        let blocking = await registry.isBlocking
        await helperClient.setBlocked(blocking)
    }
}
