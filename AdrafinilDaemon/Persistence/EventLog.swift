import Foundation
import AdrafinilShared

/// Append-only JSON-lines event log. Rotated at 10MB. Drives the "while you were away" summary.
@MainActor
final class EventLog {
    private let url: URL
    private let maxBytes: Int = 10 * 1024 * 1024
    private(set) var last: DaemonEvent?
    private(set) var lastAt: Date?

    /// `ISO8601DateFormatter` is expensive to construct; build it once rather than per append.
    private let timestampFormatter = ISO8601DateFormatter()

    init(url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.eventLogFilename)) {
        self.url = url
    }

    func append(_ event: DaemonEvent) {
        let now = Date()
        last = event
        lastAt = now
        let entry: [String: String] = [
            "t": timestampFormatter.string(from: now),
            "event": event.rawValue
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: entry) else { return }
        var line = body
        line.append(0x0A) // newline
        appendToFile(line)
        rotateIfNeeded()
    }

    private func appendToFile(_ data: Data) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
