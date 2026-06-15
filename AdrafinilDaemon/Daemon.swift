import AdrafinilShared
import Foundation
import OSLog

@MainActor
final class Daemon {
    let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "Daemon")

    let registry = AssertionRegistry()
    let helperClient = HelperClient()
    let stateStore = StateStore()
    let eventLog = EventLog()

    var settings: AdrafinilSettings = .load()

    /// User-controlled master switch. While paused, all holds are released and agent acquires are
    /// ignored, so the Mac sleeps normally. Persisted: the user quit the app expecting their Mac
    /// to sleep, and a daemon relaunch or reboot must not silently un-pause behind their back.
    private(set) var isPaused = false

    let lidMonitor = LidStateMonitor()
    let processWatcher = ProcessWatcher()
    let idleMonitor = IdleMonitor()
    let thermalMonitor = ThermalMonitor()
    let batteryMonitor = BatteryMonitor()
    let chimePlayer = ChimePlayer()
    let screenLocker = ScreenLocker()
    let systemPowerMonitor = SystemPowerMonitor()

    var appXPCServer: AppXPCServer!
    var cliServer: CLISocketServer!

    /// Pushes status changes to subscribed menu bar apps, so the app doesn't poll. Populated by
    /// `DaemonXPCService.subscribe`; fanned out by `broadcastStatus()`.
    let statusBroadcaster = StatusBroadcaster()

    private var sweepTimer: Timer?
    private var reconcileTimer: Timer?
    private var blockingObserver: Task<Void, Never>?

    /// Latches fired cutouts so the agent that was just cut off can't immediately re-pin a hot
    /// or draining Mac (see `CutoutLatch`). While latched, `handleAcquire` rejects.
    private var cutoutLatch = CutoutLatch()
    /// Re-checks the thermal latch while it's held. The thermal monitor only polls while
    /// blocking — which a cutout just ended — so without this the "has it cooled?" question
    /// would never be asked again until the lid opens.
    private var latchRecheckTimer: Timer?

    /// Whether any assertion is currently held. Mirrors the registry's blocking state (kept in sync by
    /// `observeBlockingState`) so the periodic timers can be gated on it without an async hop.
    private var isBlocking = false

    /// Records this daemon's on-disk binary at launch so an in-place app update can be detected and
    /// adopted by relaunching (see `relaunchIfUpdatedWhenIdle`).
    private let executableStaleness = ExecutableStaleness()

    /// PIDs of sniffed assertions that were released (by the user or the idle sweep) and must
    /// not be re-acquired by the sniff sweep while their process lives.
    private var sniffSuppressedPids: Set<pid_t> = []

    // "While you were away" tracking.
    private var lidClosedAt: Date?
    private var heldAtClose: [(key: String, tool: String, displayName: String, acquiredAt: Date)] = []
    /// When each lid-close-held key released while the lid was closed, so the summary reports
    /// real run durations rather than "until lid-open". Stamped by `recordAwayReleases`.
    private var awayReleasedAt: [String: Date] = [:]
    private var peakTempWhileClosed: Double?
    private var thermalCutoutWhileClosed = false
    private var lowBatteryCutoutWhileClosed = false
    private var pendingAwaySummary: AwaySummary?

    func start() async {
        log.info("Adrafinil daemon starting")

        // Restore previous state (daemon restart while agents were live). Assertions are
        // validated first: after a reboot every stored PID is stale and recycled, and restoring
        // one that now names a busy system process would re-block sleep with no agent behind it.
        if let restored = stateStore.load() {
            isPaused = restored.paused
            let outcome = RestoreFilter.partition(
                restored.assertions,
                bootTime: RestoreFilter.systemBootTime(),
                pathOf: { ProcessResolver.path(of: $0) },
            )
            if !outcome.dropped.isEmpty {
                log.notice("Dropped \(outcome.dropped.count) stale persisted assertion(s) (pre-boot or recycled pid)")
            }
            await registry.replaceAll(with: outcome.kept)
            if !outcome.dropped.isEmpty { await persistState() }
            log.info("Restored \(outcome.kept.count) assertions from state file (paused=\(self.isPaused))")
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
        isBlocking = blocking
        thermalMonitor.isBlocking = blocking
        thermalMonitor.lidClosed = lidMonitor.isLidClosed
        batteryMonitor.isBlocking = blocking
        batteryMonitor.lidClosed = lidMonitor.isLidClosed
        idleMonitor.isBlocking = blocking
        for a in await registry.snapshot() where a.pid > 0 {
            processWatcher.watch(pid: a.pid)
        }
        await syncHelperToRegistry()
        helperClient.logHelperVersion()

        updateSweepTimer()
        updateReconcileTimer()
    }

    // MARK: - Public API used by IPC servers

    /// Pause/resume the whole app. Pausing releases everything and makes `handleAcquire` a no-op
    /// until resumed; resuming lets agents re-acquire on their next hook event.
    func handleSetPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            log.notice("Paused — releasing all assertions and ignoring agent acquires until resumed")
            await registry.removeAll()
            await persistAndSync(event: .released)
            await syncHelperToRegistry()
        } else {
            log.notice("Resumed — agents can keep the Mac awake again")
            // Resume changes no assertions, so it doesn't pass through persistAndSync — persist
            // the paused bit and push the new state explicitly so the app's hero card flips
            // immediately.
            await persistState()
            await broadcastStatus()
        }
    }

    /// Outcome of an agent-hold request, so the CLI/MCP can report precisely why a hold did or
    /// didn't take.
    enum HoldResult {
        case placed(key: String, ttl: TimeInterval, count: Int)
        /// Agent holds are disabled in settings.
        case disabled
        /// The app is paused, so nothing can keep the Mac awake right now.
        case paused
        /// The acquire was refused (e.g. registry at capacity).
        case rejected(String)
    }

    /// Places an explicit agent hold: clamps the TTL to the configured cap, mints a `hold:` key,
    /// and acquires it as a `.manual` assertion (idle-exempt, TTL-bounded). Honors the
    /// `agentHoldsEnabled` master switch and the pause state.
    func handleHold(reason: String?, requestedTTL: TimeInterval?, pid: pid_t?, tool: String?) async -> HoldResult {
        guard settings.agentHoldsEnabled else {
            log.notice("hold rejected — agent holds are disabled in settings")
            return .disabled
        }
        guard !isPaused else {
            log.notice("hold rejected — Adrafinil is paused")
            return .paused
        }
        let ttl = ManualHold.clampTTL(requestedTTL, capHours: settings.manualHoldMaxHours)
        let key = ManualHold.newKey()
        let label = (tool?.isEmpty == false) ? tool! : ManualHold.defaultTool
        let assertion = Assertion(
            key: key,
            tool: label,
            reason: reason,
            pid: pid ?? -1,
            processName: label,
            ttl: ttl,
            origin: .manual,
        )
        switch await handleAcquire(assertion) {
        case .accepted:
            break
        case .paused:
            return .paused
        case .overCapacity:
            return .rejected("Too many active assertions — hold not placed.")
        case let .cutoutLatched(message):
            return .rejected(message)
        }
        let count = await registry.snapshot().count
        log.notice("hold placed key='\(key, privacy: .public)' ttl=\(Int(ttl), privacy: .public)s pid=\(pid ?? -1, privacy: .public) reason='\(reason ?? "", privacy: .public)'")
        return .placed(key: key, ttl: ttl, count: count)
    }

    /// Hard ceilings on registry size. Agent hooks produce a handful of live assertions; hundreds
    /// means a runaway or hostile local caller, and every new key rewrites state.json in full —
    /// unbounded growth is a disk/CPU sink.
    static let maxAssertions = 128
    static let maxAssertionsPerPid = 32

    enum AcquireResult: Equatable {
        case accepted
        case paused
        case overCapacity
        case cutoutLatched(String)
    }

    @discardableResult
    func handleAcquire(_ assertion: Assertion) async -> AcquireResult {
        guard !isPaused else {
            log.notice("acquire ignored — Adrafinil is paused (key='\(assertion.key, privacy: .public)')")
            return .paused
        }
        if let message = cutoutLatch.rejectionMessage {
            log.notice("acquire rejected — cutout latched (key='\(assertion.key, privacy: .public)')")
            return .cutoutLatched(message)
        }
        let snapshot = await registry.snapshot()
        if !snapshot.contains(where: { $0.key == assertion.key }) {
            guard snapshot.count < Self.maxAssertions else {
                log.error("acquire rejected — \(snapshot.count) assertions already active (key='\(assertion.key, privacy: .public)')")
                return .overCapacity
            }
            if assertion.pid > 0, snapshot.count(where: { $0.pid == assertion.pid }) >= Self.maxAssertionsPerPid {
                log.error("acquire rejected — pid \(assertion.pid) already holds \(Self.maxAssertionsPerPid) assertions")
                return .overCapacity
            }
        }
        let isNew = await registry.acquire(assertion)
        // Watch the owning process so the assertion is force-released if the agent dies without
        // firing its end hook. watch() is idempotent. pid <= 0 means the CLI
        // could not identify a real agent process and asked us not to watch.
        if assertion.pid > 0 { processWatcher.watch(pid: assertion.pid) }
        let count = await registry.snapshot().count
        log.notice("acquire key='\(assertion.key, privacy: .public)' tool='\(assertion.tool, privacy: .public)' pid=\(assertion.pid, privacy: .public) new=\(isNew, privacy: .public) -> \(count, privacy: .public) active")
        // Duplicate acquires are no-ops for the count — don't log/persist them.
        if isNew { await persistAndSync(event: .acquired) }
        return .accepted
    }

    @discardableResult
    func handleRelease(key: String) async -> Bool {
        let existed = await registry.release(key: key)
        // A released sniffed assertion must stay released: the sweep re-acquires any matched
        // process it isn't already holding, so without this a user's explicit release (or an
        // idle release) would be silently undone 30 seconds later. Suppression lasts until the
        // process exits (pruned in `processSweep`).
        if existed, key.hasPrefix(CLIRequestValidator.sniffedKeyPrefix),
           let pid = key.split(separator: ":").last.flatMap({ pid_t($0) }) {
            sniffSuppressedPids.insert(pid)
        }
        if existed {
            let count = await registry.snapshot().count
            log.notice("release key='\(key, privacy: .public)' existed=true -> \(count, privacy: .public) active")
            await persistAndSync(event: .released)
        } else {
            // Unknown key is a warning, not an error.
            log.warning("Release for unknown key '\(key)' — no-op")
        }
        return existed
    }

    func handleForceReleaseAll() async {
        await registry.removeAll()
        await persistAndSync(event: .released)
        // Push the unblock to the helper synchronously (rather than only via the edge-triggered
        // blocking stream) and await the round-trip, so callers that force-release before tearing
        // the helper down — notably uninstall — are guaranteed `disablesleep` is cleared first.
        await syncHelperToRegistry()
    }

    func currentStatus() async -> DaemonStatus {
        let snapshot = await registry.snapshot()
        // While blocking, the monitor polls and `lastReadingCelsius` is current. While idle the
        // poll is stopped (no wakeups), so read once on demand for callers that want a live temp.
        let temperature = thermalMonitor.isBlocking ? thermalMonitor.lastReadingCelsius : thermalMonitor.readNow()

        var warnings: [String] = []
        if let latchMessage = cutoutLatch.rejectionMessage {
            warnings.append(latchMessage)
        }
        if helperClient.lastApplyFailed, !snapshot.isEmpty {
            warnings.append("The sleep block couldn't be fully applied — your Mac may still sleep when the lid closes. Retrying.")
        }
        if settings.thermalCutoutEnabled, !snapshot.isEmpty, temperature == nil {
            warnings.append("CPU temperature is unreadable, so the thermal cutout can't trigger.")
        }

        return DaemonStatus(
            isBlocking: !snapshot.isEmpty,
            assertions: snapshot,
            lidClosed: lidMonitor.isLidClosed,
            helperConnected: helperClient.isConnected,
            cpuTemperatureCelsius: temperature,
            lastEvent: eventLog.last,
            lastEventAt: eventLog.lastAt,
            paused: isPaused,
            awaySummaryPending: pendingAwaySummary != nil,
            warnings: warnings,
        )
    }

    /// Encodes the current status and pushes it to every subscribed app. Called at each state
    /// transition so the app updates instantly without polling. No-op when no app is subscribed.
    private func broadcastStatus() async {
        let status = await currentStatus()
        statusBroadcaster.broadcast(status)
    }

    /// Returns and clears the pending "while you were away" summary (consume-once).
    func consumeAwaySummary() -> AwaySummary? {
        defer { pendingAwaySummary = nil }
        return pendingAwaySummary
    }

    func reloadSettings() {
        settings = AdrafinilSettings.load()
        idleMonitor.idleThresholdSeconds = TimeInterval(settings.idleReleaseSeconds)
        idleMonitor.enabled = settings.idleReleaseEnabled
        thermalMonitor.thresholdCelsius = settings.thermalThresholdCelsius
        thermalMonitor.enabled = settings.thermalCutoutEnabled
        batteryMonitor.thresholdPercent = settings.lowBatteryThresholdPercent
        batteryMonitor.enabled = settings.lowBatteryCutoutEnabled
        // The sweep only exists to auto-acquire for sniffed agents — start/stop it as that toggles.
        updateSweepTimer()
    }

    // MARK: - Internal

    private func observeBlockingState() {
        // Single long-lived consumer. Applying transitions serially (awaiting each helper
        // round-trip before handling the next) guarantees the helper reflects the latest
        // blocking state — unlike spawning a Task per edge, which could apply out of order.
        blockingObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await blocking in registry.blockingStateChanges {
                isBlocking = blocking
                thermalMonitor.isBlocking = blocking
                batteryMonitor.isBlocking = blocking
                // Gate the periodic timers on holding: the idle/death sweep and the (opt-in) agent
                // sniff only matter while we're keeping the Mac awake. No timers while idle means no
                // CPU wakeups exactly when the Mac would otherwise be asleep.
                idleMonitor.isBlocking = blocking
                updateSweepTimer()
                updateReconcileTimer()
                await helperClient.setBlocked(blocking)
                // Going idle is the safe moment to adopt a binary an update swapped in while we
                // were holding.
                relaunchIfUpdatedWhenIdle()
            }
        }
    }

    /// Adopts a binary that an in-place app update has swapped onto disk by exiting so `launchd`
    /// (KeepAlive) relaunches the daemon from the new image. Gated on being idle: restarting while
    /// holding would briefly disconnect the helper, and there's no reason to take that blip when the
    /// blocking→idle edge and every app reconnect re-check this. A no-op unless the on-disk binary
    /// actually changed, so it never fires in normal operation.
    func relaunchIfUpdatedWhenIdle() {
        guard executableStaleness.hasBeenReplaced() else { return }
        guard !isBlocking else {
            log.notice("Daemon binary replaced by an update — deferring relaunch until idle")
            return
        }
        // A fired cutout releases every assertion, so the daemon reads as idle the instant it
        // latches — exactly when this is called off the blocking→idle edge. The latch itself isn't
        // persisted, so exiting now would relaunch with an empty latch and let the held agent
        // re-acquire while the hazard is still present. Defer until the latch clears (lid opens or
        // the condition recedes); its 60s re-check timer re-runs this once it does.
        guard !cutoutLatch.isLatched else {
            log.notice("Daemon binary replaced by an update — deferring relaunch until the safety cutout clears")
            return
        }
        log.notice("Daemon binary replaced by an update — exiting so launchd relaunches the new daemon")
        exit(0)
    }

    /// While blocking, re-push the blocked state to the helper once a minute. The helper's
    /// `set(true)` re-runs the full mechanism (the policy is deliberately not short-circuited),
    /// so this heals every way the block can silently rot: a `pmset` invocation that failed once,
    /// a helper relaunch whose reapply raced, or the kernel resetting `disablesleep` outside the
    /// wake notification. Costs one `pmset` fork per minute, only while an agent is held.
    private func updateReconcileTimer() {
        if isBlocking, reconcileTimer == nil {
            reconcileTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isBlocking else { return }
                    await self.syncHelperToRegistry()
                }
            }
        } else if !isBlocking, let timer = reconcileTimer {
            timer.invalidate()
            reconcileTimer = nil
        }
    }

    /// Best-effort cleanup on SIGTERM (launchctl bootout, logout, shutdown): clear the helper's
    /// sleep block, bounded by a deadline so a wedged helper can't stall the exit past launchd's
    /// patience. Without this, `disablesleep` survives the daemon with nothing left to clear it.
    func shutdown() async {
        log.notice("SIGTERM — clearing sleep block before exit")
        await persistState()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResumer<Void> { cont.resume() }
            Task { @MainActor [helperClient] in
                await helperClient.setBlocked(false)
                once.resume(())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.resume(()) }
        }
    }

    private func wireMonitors() {
        wirePowerMonitor()
        wireLidMonitor()
        wireProcessWatcher()
        wireIdleMonitor()
        wireThermalMonitor()
        wireBatteryMonitor()
    }

    private func wirePowerMonitor() {
        systemPowerMonitor.onWake = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // The helper's clamshell-disable bit can be reset across a sleep/wake cycle, so
                // re-push the current blocking state — the helper re-applies it. The idle
                // baselines are dropped too: wall-clock advanced through sleep, and a pre-sleep
                // CPU sample would read a mid-work agent as long-idle on the first sweep.
                self.idleMonitor.resetBaselines()
                await self.syncHelperToRegistry()
            }
        }
    }

    private func wireLidMonitor() {
        lidMonitor.onChange = { [weak self] closed in
            guard let self else { return }
            Task { @MainActor in
                self.eventLog.append(closed ? .lidClosed : .lidOpened)
                self.thermalMonitor.lidClosed = closed
                self.batteryMonitor.lidClosed = closed
                // Opening the lid clears any cutout latch — the user is present, and open-lid
                // thermals/drain are macOS's problem.
                self.reevaluateCutoutLatch()
                if closed {
                    let decision = await LidActionDecider().onLidClose(
                        isBlocking: self.registry.isBlocking,
                        lockOnLidClose: self.settings.lockOnLidClose,
                        soundOnLidClose: self.settings.soundOnLidClose,
                    )
                    if decision.shouldChime {
                        self.chimePlayer.playLidCloseChime(
                            volume: self.settings.soundVolume,
                            chimeName: self.settings.chimeName,
                        )
                    }
                    // Secure the kept-awake machine: lock the screen on lid close. Explicit lock
                    // works even when an idle-lock-prevention assertion is held, and the system
                    // stays awake (disablesleep) so the agent keeps running.
                    if decision.shouldLock {
                        self.screenLocker.lock()
                    }
                    // The awaits above can interleave with a rapid re-open; beginning
                    // away-tracking for a lid that is already open again would dangle until the
                    // NEXT open and report a summary spanning the whole intervening period.
                    if decision.shouldBeginAwayTracking, self.lidMonitor.isLidClosed {
                        await self.beginAwayTracking(snapshot: self.registry.snapshot())
                    }
                } else if !self.lidMonitor.isLidClosed {
                    await self.finishAwayTracking()
                }
                // Push the lid-state change (and any freshly-pending away summary) to the app.
                await self.broadcastStatus()
            }
        }
    }

    private func wireProcessWatcher() {
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
    }

    private func wireIdleMonitor() {
        idleMonitor.onIdleRelease = { [weak self] keys in
            guard let self else { return }
            Task { @MainActor in
                var released = 0
                for key in keys where await self.registry.release(key: key) {
                    released += 1
                }
                if released > 0 { await self.persistAndSync(event: .idleRelease) }
            }
        }
        idleMonitor.assertionSource = { [weak self] in
            await self?.registry.snapshot() ?? []
        }
        idleMonitor.idleThresholdSeconds = TimeInterval(settings.idleReleaseSeconds)
        idleMonitor.enabled = settings.idleReleaseEnabled
        idleMonitor.start()
    }

    private func wireThermalMonitor() {
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
                self.cutoutLatch.trip(.thermal)
                self.updateLatchRecheckTimer()
                await self.registry.removeAll()
                await self.persistAndSync(event: .thermalCutout)
            }
        }
        thermalMonitor.start()
    }

    private func wireBatteryMonitor() {
        batteryMonitor.thresholdPercent = settings.lowBatteryThresholdPercent
        batteryMonitor.enabled = settings.lowBatteryCutoutEnabled
        batteryMonitor.onReading = { [weak self] _, _ in
            // IOKit power-source events keep firing while idle (plug/unplug, charge), so this is
            // the battery latch's recovery path: plugging in clears it immediately.
            MainActor.assumeIsolated { self?.reevaluateCutoutLatch() }
        }
        batteryMonitor.onCutout = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.log.warning("Low-battery cutout triggered — releasing all assertions")
                if self.lidClosedAt != nil { self.lowBatteryCutoutWhileClosed = true }
                self.cutoutLatch.trip(.lowBattery)
                self.updateLatchRecheckTimer()
                await self.registry.removeAll()
                await self.persistAndSync(event: .lowBatteryCutout)
            }
        }
        batteryMonitor.start()
    }

    /// Re-evaluates the cutout latch against current readings, clearing causes whose hazard
    /// receded (with hysteresis) and broadcasting so the UI drops its warning.
    private func reevaluateCutoutLatch() {
        guard cutoutLatch.isLatched else { return }
        let cleared = cutoutLatch.update(
            temperatureCelsius: thermalMonitor.lastReadingCelsius,
            thermalThresholdCelsius: settings.thermalThresholdCelsius,
            batteryPercent: batteryMonitor.lastPercent,
            onBattery: batteryMonitor.lastOnBattery,
            batteryThresholdPercent: settings.lowBatteryThresholdPercent,
            lidClosed: lidMonitor.isLidClosed,
        )
        if !cleared.isEmpty {
            log.notice("Cutout latch cleared: \(cleared.map(\.rawValue).joined(separator: ","), privacy: .public)")
            updateLatchRecheckTimer()
            Task { @MainActor in await self.broadcastStatus() }
            // A relaunch deferred because the latch was held can now proceed (if still idle) — the
            // cutout that was protecting state has receded, so it's safe to adopt an updated binary.
            relaunchIfUpdatedWhenIdle()
        }
    }

    /// While the thermal latch is held, sample the temperature once a minute so "has it cooled?"
    /// gets asked — the thermal monitor's own poll is gated on blocking, which the cutout ended.
    /// The battery latch needs no timer: IOKit power events fire regardless of blocking.
    private func updateLatchRecheckTimer() {
        let needed = cutoutLatch.active.contains(.thermal)
        if needed, latchRecheckTimer == nil {
            latchRecheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    _ = self.thermalMonitor.readNow()
                    self.reevaluateCutoutLatch()
                }
            }
        } else if !needed, let timer = latchRecheckTimer {
            timer.invalidate()
            latchRecheckTimer = nil
        }
    }

    /// Starts or stops the agent-detection sweep. The sweep auto-acquires for **name-matched** agents
    /// (claude, codex, …) found running without their hook installed, but only when:
    ///
    /// - the user opted into `autoAcquireForKnownAgents` (off by default), **and**
    /// - we are already holding (`isBlocking`).
    ///
    /// The holding gate is the important one: it means there is **no background timer while the daemon
    /// is idle** — exactly when the Mac would otherwise be asleep and a periodic wakeup would waste a
    /// power cycle. So detection-by-sniff is a thing we do *while already awake for an agent* (to catch
    /// a concurrent one), never a background poll that initiates a hold from nothing.
    ///
    /// Gateway agents (Hermes) are intentionally **not** sniff-acquired — their 24/7 process is always
    /// present, so sniffing it would either run a forever-timer or false-acquire on background CPU.
    /// They rely on their hooks (`pre_gateway_dispatch` → acquire / `on_session_end` → release), which
    /// fire on real turns. (Re-arming exit-watch for held assertions is handled in `start()` and every
    /// `handleAcquire`; `kqueue` watches persist until exit — the sweep isn't needed for that.)
    private func updateSweepTimer() {
        let needed = isBlocking && settings.processSniffingEnabled && settings.autoAcquireForKnownAgents
        if needed, sweepTimer == nil {
            sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.processSweep() }
            }
        } else if !needed, let timer = sweepTimer {
            timer.invalidate()
            sweepTimer = nil
        }
    }

    private func processSweep() async {
        // Re-check the gates in case settings or the holding state changed between scheduling and firing.
        guard isBlocking, settings.processSniffingEnabled, settings.autoAcquireForKnownAgents else { return }
        let snapshot = await registry.snapshot()
        let watchedPids = Set(snapshot.map(\.pid))
        sniffSuppressedPids = sniffSuppressedPids.filter { kill($0, 0) == 0 || errno == EPERM }

        for proc in ProcessResolver.runningProcesses() {
            guard !watchedPids.contains(proc.pid), !sniffSuppressedPids.contains(proc.pid) else { continue }
            // Name/path match only — gateway agents (argv-matched) are deliberately not sniff-acquired.
            guard let kind = AgentKind.forRunningProcess(name: proc.name, path: proc.path),
                  !kind.isGatewayScoped else { continue }

            let assertion = Assertion(
                key: "\(CLIRequestValidator.sniffedKeyPrefix)\(kind.rawValue):\(proc.pid)",
                tool: kind.rawValue,
                reason: "auto (process sniffing)",
                pid: proc.pid,
                processName: proc.name,
                origin: .sniffed,
            )
            log.info("Auto-acquiring for sniffed agent \(kind.rawValue) (pid \(proc.pid))")
            await handleAcquire(assertion)
        }
    }

    private func beginAwayTracking(snapshot: [Assertion]) {
        lidClosedAt = Date()
        heldAtClose = snapshot.map {
            ($0.key, $0.tool, AgentKind(rawValue: $0.tool)?.displayName ?? $0.tool, $0.acquiredAt)
        }
        awayReleasedAt = [:]
        peakTempWhileClosed = thermalMonitor.lastReadingCelsius
        thermalCutoutWhileClosed = false
        lowBatteryCutoutWhileClosed = false
    }

    /// Stamps the release time for any lid-close-held key that has disappeared from the
    /// registry. Called on every persisted mutation, so it catches every release path — hooks,
    /// idle sweep, process exit, cutouts — without each of them knowing about away-tracking.
    private func recordAwayReleases(currentKeys: Set<String>) {
        guard lidClosedAt != nil else { return }
        for held in heldAtClose where awayReleasedAt[held.key] == nil && !currentKeys.contains(held.key) {
            awayReleasedAt[held.key] = Date()
        }
    }

    private func finishAwayTracking() async {
        defer {
            lidClosedAt = nil
            heldAtClose = []
            awayReleasedAt = [:]
        }
        guard let closedAt = lidClosedAt, !heldAtClose.isEmpty else { return }
        let openedAt = Date()
        let activeKeys = await Set(registry.snapshot().map(\.key))
        let held = heldAtClose.map {
            AwaySummaryBuilder.HeldAgent(key: $0.key, tool: $0.tool, displayName: $0.displayName, acquiredAt: $0.acquiredAt)
        }
        let summary = AwaySummaryBuilder().build(
            heldAtClose: held,
            activeKeys: activeKeys,
            releasedAt: awayReleasedAt,
            closedAt: closedAt,
            openedAt: openedAt,
            peakTemperatureCelsius: peakTempWhileClosed,
            thermalCutout: thermalCutoutWhileClosed,
            lowBatteryCutout: lowBatteryCutoutWhileClosed,
        )
        pendingAwaySummary = summary
        if let summary {
            log.info("Away summary: \(summary.finished.count) finished, \(summary.stillActive.count) still active")
        }
    }

    private func persistAndSync(event: DaemonEvent) async {
        eventLog.append(event)
        await persistState()
        // Helper sync is edge-triggered via the registry's blockingStateChanges stream —
        // no redundant XPC round-trip on every acquire/release here.
        await broadcastStatus()
    }

    private func persistState() async {
        let snapshot = await registry.snapshot()
        recordAwayReleases(currentKeys: Set(snapshot.map(\.key)))
        stateStore.save(PersistedDaemonState(assertions: snapshot, paused: isPaused))
    }

    private func syncHelperToRegistry() async {
        let blocking = await registry.isBlocking
        await helperClient.setBlocked(blocking)
    }
}
