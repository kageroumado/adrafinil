import AdrafinilShared
import Foundation
import Observation
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
    ) {
        self.provider = provider
        self.agentHooks = agentHooks
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
        }
    }

    /// Applies a fresh status (from a push or a fetch) and, only when the daemon flags one, fetches
    /// the pending away summary — so the summary costs a round-trip exactly when it exists, not on
    /// every update.
    private func apply(_ status: DaemonStatus) {
        self.status = status
        lastError = nil
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
        ) {
            self.init(
                provider: PreviewStatusProvider(status: previewStatus, awaySummary: awaySummary, error: error),
                agentHooks: PreviewAgentHooksProvider(driftedAgents.map { ($0, .modifiedExternally) }),
                poll: false,
            )
            if let error {
                self.lastError = error.localizedDescription
            } else {
                self.status = previewStatus
            }
            self.driftedAgents = driftedAgents
        }
    #endif
}
