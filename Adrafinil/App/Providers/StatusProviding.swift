import AdrafinilShared
import Foundation

/// The daemon-facing operations the menu-bar UI needs. The live implementation is `DaemonClient`
/// (XPC to AdrafinilDaemon); previews and the gallery inject `PreviewStatusProvider` so every view
/// can render without a running daemon.
@MainActor
protocol StatusProviding {
    func fetchStatus() async throws -> DaemonStatus
    func forceReleaseAll() async throws
    func releaseAssertion(key: String) async throws
    func setPaused(_ paused: Bool) async throws
    func reloadSettings() async throws
    func consumeAwaySummary() async -> AwaySummary?
    /// A live stream of status pushed by the source. The live client bridges the daemon's XPC push;
    /// previews/mocks return a finished stream and rely on explicit `fetchStatus()` refreshes.
    func statusUpdates() -> AsyncStream<DaemonStatus>
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

        func releaseAssertion(key: String) async throws {
            status.assertions.removeAll { $0.key == key }
            status.isBlocking = !status.assertions.isEmpty
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

        /// Previews don't push; the model seeds its snapshot directly. Finish immediately so the
        /// consuming task ends cleanly rather than awaiting forever.
        func statusUpdates() -> AsyncStream<DaemonStatus> {
            AsyncStream { $0.finish() }
        }
    }
#endif
