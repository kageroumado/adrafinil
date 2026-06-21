import AdrafinilShared
import Foundation
import Observation
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let adrafinilAwaySummaryReceived = Notification.Name("glass.kagerou.adrafinil.awaySummaryReceived")
}

/// Observable model the menu bar UI binds to. Driven by the daemon's push stream
/// (`StatusProviding.statusUpdates()`) rather than polling, so neither process wakes the CPU while
/// nothing changes. A slow heartbeat backstops a silently-wedged connection.
///
/// When the daemon flags a pending `AwaySummary` (on lid-open after a kept-awake period), this model
/// consumes it (one call, only when flagged) and posts `adrafinilAwaySummaryReceived` on the default
/// `NotificationCenter` with the summary as `object` — `AppDelegate` subscribes to this and delivers
/// a native system notification via `AwayNotifier`.
@MainActor
@Observable
final class AppStatusModel {
    var status: DaemonStatus?
    var lastError: String?

    /// Why the daemon is unreachable, when it is. `.ok` whenever we have live status. The others mean
    /// the daemon's background service won't recover on its own:
    /// - `.needsApproval` — registered but awaiting the user's "Allow in the Background" (authoritative
    ///   from `SMAppService`; flagged on the first failure).
    /// - `.notRegistered` — never registered; setup didn't complete (likewise authoritative).
    /// - `.unreachable` — `SMAppService` reports it *enabled*, yet calls keep failing. A brief miss is
    ///   normal (the daemon relaunches to adopt an updated binary), so this is flagged only after a
    ///   sustained outage. Covers the case where a corrupted Background Task Management record reads as
    ///   enabled while launchd never actually instantiated the agent.
    /// Drives the actionable popover card and the one-shot alert.
    enum ServiceState: Equatable { case ok, needsApproval, notRegistered, unreachable }
    var serviceState: ServiceState = .ok

    /// Progress of an automatic or user-initiated repair (re-register the services and verify they
    /// answer). `.failed` carries the reason and drives the "remove Adrafinil in Login Items" guidance
    /// — the manual fix when re-registration can't clear the wedged records.
    enum RepairPhase: Equatable { case idle, repairing, failed(String) }
    var repairPhase: RepairPhase = .idle

    /// Connected agents whose Adrafinil hook has drifted from the canonical form, so the daemon may
    /// no longer notice when they work. Surfaced as a warning in the popover (not just buried in the
    /// Agents settings tab) because a silent drift means the Mac quietly stops staying awake for that
    /// agent. Recomputed by `refreshAgentHealth()` when the popover opens.
    var driftedAgents: [AgentKind] = []

    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var revertNudgeTask: Task<Void, Never>?
    /// Guards against firing overlapping summary consumes if pushes arrive while one is in flight.
    @ObservationIgnored private var consumingSummary = false
    @ObservationIgnored private let provider: any StatusProviding
    @ObservationIgnored private let agentHooks: any AgentHooksProviding
    /// Whether this is the live menu-bar model (vs. a static preview/gallery snapshot). Gates the
    /// service-reachability detection so previews — which drive `refresh()` on a timer and would
    /// otherwise trip the unreachable threshold, overwrite the previewed `serviceState`, and even
    /// fire a real repair — stay fixed at whatever state they were constructed with.
    @ObservationIgnored private let isLive: Bool
    /// Resolves the background service's registration state when a call fails. Injected so previews
    /// and tests don't consult the real `SMAppService` (which would report `.notRegistered` off-device).
    @ObservationIgnored private let probeServiceState: @MainActor () -> ServiceState
    /// One-shot guard so an unreachable-service alert fires once per outage, not on every heartbeat.
    /// Reset when the daemon becomes reachable again, so a later recurrence re-alerts.
    @ObservationIgnored private var didAlertServiceProblem = false
    /// Consecutive failed daemon calls. Lets the `.unreachable` case (service enabled but not
    /// answering) wait out a normal relaunch instead of alarming on a single transient miss.
    @ObservationIgnored private var consecutiveFailures = 0
    /// Whether we've already auto-attempted a repair this outage, so a wedged service is self-healed
    /// once (not on every heartbeat). Re-armed when the daemon becomes reachable again.
    @ObservationIgnored private var autoRepairAttempted = false
    /// How many consecutive failures mark an enabled-but-silent service as genuinely wedged. With the
    /// 60 s heartbeat that's a few minutes closed; the popover's 5 s tick reaches it faster when open.
    private static let unreachableFailureThreshold = 3

    #if DEBUG
        /// When the debug control panel is driving a service-problem scenario, it sets `serviceState`
        /// and `repairPhase` directly; this stops the reachability evaluator from reclassifying them or
        /// kicking off a real (system-touching) repair.
        @ObservationIgnored var debugOwnsServiceState = false
    #endif

    /// How often the heartbeat re-fetches as a safety net behind the push stream. Push handles every
    /// real change instantly; this only guards a wedged connection and refreshes a stale temperature.
    private static let heartbeatInterval: TimeInterval = 60

    /// - Parameters:
    ///   - provider: the daemon-facing data source. Defaults to the shared live XPC client; previews
    ///     and the gallery inject a `PreviewStatusProvider`.
    ///   - poll: when `true` (production), subscribes to pushes + runs the heartbeat. Previews pass
    ///     `false` for a fixed snapshot.
    init(
        provider: any StatusProviding = DaemonClient.shared,
        agentHooks: any AgentHooksProviding = LiveAgentHooksProvider(),
        poll: Bool = true,
        probeServiceState: @escaping @MainActor () -> ServiceState = AppStatusModel.liveServiceState,
    ) {
        self.provider = provider
        self.agentHooks = agentHooks
        self.probeServiceState = probeServiceState
        self.isLive = poll
        if poll {
            // Set up the push subscription synchronously (the AsyncStream builder runs now), so the
            // connection is established with its callback before the initial refresh reuses it.
            let updates = provider.statusUpdates()
            self.subscriptionTask = Task { @MainActor [weak self] in
                for await status in updates {
                    guard let self else { break }
                    apply(status)
                }
            }
            // Heartbeat in `.common` mode: a default-mode timer is suspended while the menu-bar
            // popover holds the run loop in event-tracking, which would stall the backstop.
            let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            self.heartbeatTimer = t
        }
        Task { @MainActor in await refresh() } // immediate first snapshot
    }

    isolated deinit {
        subscriptionTask?.cancel()
        heartbeatTimer?.invalidate()
        revertNudgeTask?.cancel()
    }

    func refresh() async {
        do {
            try await apply(provider.fetchStatus())
        } catch {
            lastError = error.localizedDescription
            evaluateServiceReachability()
        }
    }

    /// The live mapping from the LaunchAgent's `SMAppService` registration to a `ServiceState`.
    /// `.enabled` means the daemon should be reachable, so a failed call is transient (`.ok` here,
    /// keeping the generic "isn't responding" path); the other states mean it can't come up at all.
    static func liveServiceState() -> ServiceState {
        switch SMAppService.agent(plistName: "LaunchAgent.plist").status {
        case .enabled: .ok
        case .requiresApproval: .needsApproval
        default: .notRegistered
        }
    }

    /// Called when a daemon call fails. Distinguishes a transient hiccup (service enabled, just
    /// wedged or relaunching — keep retrying quietly) from a service that will never come up
    /// (un-approved or unregistered). For the latter, surface the actionable state and alert the user
    /// once — the app would otherwise retry the XPC connection forever with nothing said. Skipped
    /// during first-run, when the setup window owns the approval experience.
    private func evaluateServiceReachability() {
        guard isLive else { return } // static previews/gallery: keep the constructed state fixed
        #if DEBUG
            if debugOwnsServiceState { return } // debug panel is driving the scenario
        #endif
        guard !HelperInstaller.isFirstRun else { return }
        consecutiveFailures += 1
        let probe = probeServiceState()
        let detected: ServiceState
        switch probe {
        case .needsApproval, .notRegistered, .unreachable:
            // Authoritative from SMAppService — the service can't come up. Flag on the first failure.
            detected = probe
        case .ok:
            // SMAppService says enabled, yet the call failed. Tolerate a brief miss (binary-adoption
            // relaunch); only a sustained outage is a real wedge worth surfacing.
            guard consecutiveFailures >= Self.unreachableFailureThreshold else { return }
            detected = .unreachable
        }
        serviceState = detected

        // Don't re-alert or re-trigger while a repair is already running.
        guard repairPhase != .repairing else { return }

        // The enabled-but-wedged case is the one we can fix without the user: re-register the services
        // once. (A corrupt record can read as "enabled" while launchd never instantiated the agent.)
        // Approval / not-registered states need the user, so they go straight to an alert + card.
        // Set `.repairing` synchronously before launching the task, so a refresh that lands in the
        // gap sees the guard above and can't fire a premature alert.
        if detected == .unreachable, !autoRepairAttempted {
            autoRepairAttempted = true
            repairPhase = .repairing
            Task { @MainActor in await performRepair() }
            return
        }

        alertServiceProblemOnce(detected)
    }

    /// Fires the unreachable-service notification at most once per outage. Reset by `apply` when the
    /// daemon is reachable again.
    private func alertServiceProblemOnce(_ reason: ServiceState) {
        guard reason != .ok, !didAlertServiceProblem else { return }
        didAlertServiceProblem = true
        AwayNotifier.shared.deliverServiceUnavailable(reason: reason)
    }

    /// Re-registers the background services and verifies the daemon answers — the recovery path for an
    /// installation whose registration records got wedged (e.g. after an in-place update on a machine
    /// whose first install never brought the agent up). Run automatically once per outage for the
    /// wedged case, and on demand from the popover's Repair button. On success the freshly-registered
    /// services come up on the current (updated) binaries; on failure it surfaces the manual-reset
    /// guidance.
    func repair() async {
        guard repairPhase != .repairing else { return }
        repairPhase = .repairing
        await performRepair()
    }

    /// The repair worker. Assumes `repairPhase` is already `.repairing` (set by `repair()` or by the
    /// auto-repair trigger). Split out so the auto-trigger can mark the phase synchronously before
    /// awaiting, closing the window for a premature alert.
    private func performRepair() async {
        switch await HelperInstaller.repairServices() {
        case .reregistered:
            if await verifyDaemonReachable() {
                repairPhase = .idle
                await refresh() // pulls live status; `apply` clears serviceState and re-arms alerts
            } else {
                repairFailed("It re-registered, but the background service still isn't responding.")
            }
        case .needsApproval:
            repairPhase = .idle
            serviceState = .needsApproval
            alertServiceProblemOnce(.needsApproval)
        case let .failed(message):
            repairFailed(message)
        }
    }

    private func repairFailed(_ message: String) {
        repairPhase = .failed(message)
        // Now that the automatic fix has failed, tell the user (once) so they can do the manual reset.
        alertServiceProblemOnce(.unreachable)
    }

    /// Polls the daemon briefly after a re-register, since launchd takes a moment to bring the agent
    /// up. Uses the injected provider so previews/tests don't hit the real XPC client.
    private func verifyDaemonReachable() async -> Bool {
        for _ in 0 ..< 8 {
            if await (try? provider.fetchStatus()) != nil { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Applies a fresh status (from a push or a fetch) and, only when the daemon flags one, fetches
    /// the pending away summary — so the summary costs a round-trip exactly when it exists, not on
    /// every update.
    private func apply(_ status: DaemonStatus) {
        self.status = status
        lastError = nil
        // Live data means the daemon is reachable: clear any unreachable/repair state and re-arm the
        // alert and auto-repair so a future outage is handled afresh.
        serviceState = .ok
        repairPhase = .idle
        didAlertServiceProblem = false
        consecutiveFailures = 0
        autoRepairAttempted = false
        scheduleCutoutRevertNudge(for: status)
        guard status.awaySummaryPending, !consumingSummary else { return }
        consumingSummary = true
        Task { @MainActor in
            defer { consumingSummary = false }
            guard let summary = await provider.consumeAwaySummary() else { return }
            NotificationCenter.default.post(name: .adrafinilAwaySummaryReceived, object: summary)
        }
    }

    /// The menu-bar icon shows a transient red state for 30 s after a cutout, but pushes only
    /// arrive on state *changes* — and a cutout just released everything, so the daemon goes
    /// quiet exactly then. Nudge observers right after the window closes so the icon reverts on
    /// time, instead of lingering red until the next heartbeat.
    private func scheduleCutoutRevertNudge(for status: DaemonStatus) {
        revertNudgeTask?.cancel()
        guard status.lastEvent == .thermalCutout || status.lastEvent == .lowBatteryCutout,
              let at = status.lastEventAt else { return }
        let remaining = 30.2 - Date().timeIntervalSince(at)
        guard remaining > 0 else { return }
        revertNudgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self, let current = self.status else { return }
            self.status = current
        }
    }

    /// Recomputes which connected agents have drifted from Adrafinil's canonical hook. A few small
    /// config-file reads; called when the popover opens rather than on the heartbeat, since hook
    /// configs only change when the user (or an update) edits them, not on daemon activity.
    func refreshAgentHealth() {
        driftedAgents = agentHooks.detectedAgents().filter {
            agentHooks.installState(for: $0) == .modifiedExternally
        }
    }

    func forceReleaseAll() async {
        try? await provider.forceReleaseAll()
        await refresh()
    }

    /// Releases a single assertion (e.g. cancelling an agent hold from its popover row), then
    /// refreshes so the row disappears immediately.
    func releaseAssertion(key: String) async {
        try? await provider.releaseAssertion(key: key)
        await refresh()
    }

    /// Pause (`true`) or resume (`false`) the whole app, then refresh so the UI reflects it now.
    func setPaused(_ paused: Bool) async {
        try? await provider.setPaused(paused)
        await refresh()
    }

    #if DEBUG
        /// Fixed-snapshot model for previews and the gallery: seeds `status`/`awaySummary` synchronously
        /// and does not poll, so a scenario renders deterministically without a daemon.
        convenience init(
            previewStatus: DaemonStatus,
            awaySummary: AwaySummary? = nil,
            error: (any Error)? = nil,
            driftedAgents: [AgentKind] = [],
            serviceState: ServiceState = .ok,
            repairPhase: RepairPhase = .idle,
        ) {
            self.init(
                provider: PreviewStatusProvider(status: previewStatus, awaySummary: awaySummary, error: error),
                agentHooks: PreviewAgentHooksProvider(driftedAgents.map { ($0, .modifiedExternally) }),
                poll: false,
                // Off-device `SMAppService` would report `.notRegistered`; pin previews/tests to `.ok`
                // so a fixture with an injected error renders the generic error card, not the
                // approval/setup states (those have their own dedicated previews).
                probeServiceState: { .ok },
            )
            if let error {
                self.lastError = error.localizedDescription
            } else {
                self.status = previewStatus
            }
            self.driftedAgents = driftedAgents
            self.serviceState = serviceState
            self.repairPhase = repairPhase
        }
    #endif
}
