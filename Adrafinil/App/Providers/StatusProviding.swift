import Foundation
import AdrafinilShared

/// The daemon-facing operations the menu-bar UI needs. The live implementation is `DaemonClient`
/// (XPC to AdrafinilDaemon); previews and the gallery inject `PreviewStatusProvider` so every view
/// can render without a running daemon.
@MainActor
protocol StatusProviding {
    func fetchStatus() async throws -> DaemonStatus
    func forceReleaseAll() async throws
    func setPaused(_ paused: Bool) async throws
    func reloadSettings() async throws
    func consumeAwaySummary() async -> AwaySummary?
}

extension DaemonClient: StatusProviding {}

#if DEBUG
/// A fixed-snapshot `StatusProviding` for previews and the gallery. Returns a canned `DaemonStatus`
/// (or throws a canned error to exercise the daemon-unreachable path), and serves a one-shot
/// away-summary so the lid-open panel can be previewed.
@MainActor
final class PreviewStatusProvider: StatusProviding {
    var status: DaemonStatus
    private var pendingSummary: AwaySummary?
    private let error: (any Error)?

    init(status: DaemonStatus, awaySummary: AwaySummary? = nil, error: (any Error)? = nil) {
        self.status = status
        self.pendingSummary = awaySummary
        self.error = error
    }

    func fetchStatus() async throws -> DaemonStatus {
        if let error { throw error }
        return status
    }

    func forceReleaseAll() async throws {
        status.assertions = []
        status.isBlocking = false
    }

    func setPaused(_ paused: Bool) async throws {
        status.paused = paused
        if paused {
            status.assertions = []
            status.isBlocking = false
        }
    }

    func reloadSettings() async throws {}

    func consumeAwaySummary() async -> AwaySummary? {
        defer { pendingSummary = nil }
        return pendingSummary
    }
}
#endif
