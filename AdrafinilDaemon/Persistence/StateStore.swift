import AdrafinilShared
import Foundation

/// Persists the daemon's state (live assertions + the paused bit) so restarts don't drop live
/// agent sessions or silently un-pause a paused Adrafinil.
final class StateStore: @unchecked Sendable {
    private let url: URL

    init(url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.stateFilename)) {
        self.url = url
    }

    func load() -> PersistedDaemonState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PersistedDaemonState.decode(from: data)
    }

    func save(_ state: PersistedDaemonState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort persistence
        }
    }
}
