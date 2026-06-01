import Foundation
import AdrafinilShared
import SwiftUI
import Observation

extension Notification.Name {
    static let adrafinilAwaySummaryReceived = Notification.Name("glass.kagerou.adrafinil.awaySummaryReceived")
}

/// Observable model the menu bar UI binds to. Driven by the daemon's push stream
/// (`StatusProviding.statusUpdates()`) rather than polling, so neither process wakes the CPU while
/// nothing changes. A slow heartbeat backstops a silently-wedged connection.
///
/// When the daemon flags a pending `AwaySummary` (on lid-open after a kept-awake period), this model:
/// 1. Consumes it (one call, only when flagged) and sets `awaySummary` (observable by SwiftUI views).
/// 2. Posts `adrafinilAwaySummaryReceived` on the default `NotificationCenter`
///    with the summary as `object` — `AppDelegate` subscribes to this and delivers
///    a native system notification via `AwayNotifier`.
@MainActor
@Observable
final class AppStatusModel {
    var status: DaemonStatus?
    var lastError: String?

    /// Non-nil while a lid-open summary panel is being shown. Cleared when the
    /// panel is dismissed (either by the user or the 8-second auto-dismiss timer).
    var awaySummary: AwaySummary?

    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTimer: Timer?
    /// Guards against firing overlapping summary consumes if pushes arrive while one is in flight.
    @ObservationIgnored private var consumingSummary = false
    @ObservationIgnored private let provider: any StatusProviding

    /// How often the heartbeat re-fetches as a safety net behind the push stream. Push handles every
    /// real change instantly; this only guards a wedged connection and refreshes a stale temperature.
    private static let heartbeatInterval: TimeInterval = 60

    /// - Parameters:
    ///   - provider: the daemon-facing data source. Defaults to the shared live XPC client; previews
    ///     and the gallery inject a `PreviewStatusProvider`.
    ///   - poll: when `true` (production), subscribes to pushes + runs the heartbeat. Previews pass
    ///     `false` for a fixed snapshot.
    init(provider: any StatusProviding = DaemonClient.shared, poll: Bool = true) {
        self.provider = provider
        if poll {
            // Set up the push subscription synchronously (the AsyncStream builder runs now), so the
            // connection is established with its callback before the initial refresh reuses it.
            let updates = provider.statusUpdates()
            subscriptionTask = Task { @MainActor [weak self] in
                for await status in updates {
                    guard let self else { break }
                    self.apply(status)
                }
            }
            // Heartbeat in `.common` mode: a default-mode timer is suspended while the menu-bar
            // popover holds the run loop in event-tracking, which would stall the backstop.
            let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            heartbeatTimer = t
        }
        Task { @MainActor in await refresh() }  // immediate first snapshot
    }

    isolated deinit {
        subscriptionTask?.cancel()
        heartbeatTimer?.invalidate()
    }

    func refresh() async {
        do {
            apply(try await provider.fetchStatus())
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
        guard status.awaySummaryPending, !consumingSummary else { return }
        consumingSummary = true
        Task { @MainActor in
            defer { consumingSummary = false }
            guard let summary = await provider.consumeAwaySummary() else { return }
            awaySummary = summary
            NotificationCenter.default.post(
                name: .adrafinilAwaySummaryReceived,
                object: summary,
                userInfo: ["model": self]
            )
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
    convenience init(previewStatus: DaemonStatus, awaySummary: AwaySummary? = nil, error: (any Error)? = nil) {
        self.init(provider: PreviewStatusProvider(status: previewStatus, awaySummary: awaySummary, error: error), poll: false)
        if let error {
            self.lastError = error.localizedDescription
        } else {
            self.status = previewStatus
        }
        self.awaySummary = awaySummary
    }
#endif
}
