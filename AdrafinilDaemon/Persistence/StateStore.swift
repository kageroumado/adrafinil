import Foundation
import AdrafinilShared

/// Persists the current assertion set to disk so daemon restarts don't drop live agent sessions.
final class StateStore: @unchecked Sendable {
    private let url: URL

    init(url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.stateFilename)) {
        self.url = url
    }

    func load() -> [Assertion]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Assertion].self, from: data)
    }

    func save(_ assertions: [Assertion]) {
        do {
            let data = try JSONEncoder().encode(assertions)
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort persistence
        }
    }
}
