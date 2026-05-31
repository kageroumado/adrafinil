import Foundation
import AdrafinilShared
import SwiftUI
import Observation

extension Notification.Name {
    static let adrafinilAwaySummaryReceived = Notification.Name("glass.kagerou.adrafinil.awaySummaryReceived")
}

/// Observable model the menu bar UI binds to. Polls the daemon every 2s.
///
/// When a fresh `AwaySummary` is received from the daemon, this model:
/// 1. Sets `awaySummary` (observable by SwiftUI views).
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

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let provider: any StatusProviding

    /// - Parameters:
    ///   - provider: the daemon-facing data source. Defaults to the live XPC client; previews and
    ///     the gallery inject a `PreviewStatusProvider`.
    ///   - poll: when `true` (production), refreshes every 2s. Previews pass `false` for a fixed snapshot.
    init(provider: any StatusProviding = DaemonClient(), poll: Bool = true) {
        self.provider = provider
        Task { @MainActor in await refresh() }
        if poll {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    func refresh() async {
        do {
            status = try await provider.fetchStatus()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        if let summary = await provider.consumeAwaySummary() {
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
