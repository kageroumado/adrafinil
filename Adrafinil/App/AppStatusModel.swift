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
///    with the summary as `object` — `AppDelegate` subscribes to this to drive
///    `LidOpenSummaryController` (SPEC §7.3).
@MainActor
@Observable
final class AppStatusModel {
    var status: DaemonStatus?
    var lastError: String?

    /// Non-nil while a lid-open summary panel is being shown. Cleared when the
    /// panel is dismissed (either by the user or the 8-second auto-dismiss timer).
    var awaySummary: AwaySummary?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let client = DaemonClient()

    init() {
        Task { @MainActor in await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        do {
            status = try await client.fetchStatus()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        if let summary = await client.consumeAwaySummary() {
            awaySummary = summary
            NotificationCenter.default.post(
                name: .adrafinilAwaySummaryReceived,
                object: summary,
                userInfo: ["model": self]
            )
        }
    }

    func forceReleaseAll() async {
        try? await client.forceReleaseAll()
        await refresh()
    }
}
