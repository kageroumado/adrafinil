import AdrafinilShared
import Foundation
import OSLog

/// Append-only JSON-lines event log. Rotated at 10MB. Drives the "while you were away" summary.
@MainActor
final class EventLog {
    private let url: URL
    private let maxBytes: Int = 10 * 1_024 * 1_024
    private(set) var last: DaemonEvent?
    private(set) var lastAt: Date?

    private let log = Logger(subsystem: AdrafinilConstants.appBundleID, category: "EventLog")
    /// `ISO8601DateFormatter` is expensive to construct; build it once rather than per append.
    private let timestampFormatter = ISO8601DateFormatter()

    /// One long-lived handle positioned at end-of-file, reopened after rotation — rather than a fresh
    /// open + seek + close on every append. `bytesWritten` mirrors the file size so rotation needs no
    /// per-append stat.
    private var handle: FileHandle?
    private var bytesWritten: Int = 0

    init(url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.eventLogFilename)) {
        self.url = url
    }

    isolated deinit { try? handle?.close() }

    func append(_ event: DaemonEvent) {
        let now = Date()
        last = event
        lastAt = now
        let entry: [String: String] = [
            "t": timestampFormatter.string(from: now),
            "event": event.rawValue,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: entry) else { return }
        var line = body
        line.append(0x0A) // newline
        write(line)
        rotateIfNeeded()
    }

    /// The append handle, opened (and the file created) on first use and kept open thereafter.
    private func appendHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        do {
            let opened = try FileHandle(forWritingTo: url)
            bytesWritten = try Int(opened.seekToEnd())
            handle = opened
            return opened
        } catch {
            log.error("Failed to open event log at \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write(_ data: Data) {
        guard let handle = appendHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            log.error("Failed to append to event log: \(error.localizedDescription, privacy: .public)")
            // Drop the handle so the next append retries from a clean open.
            try? handle.close()
            self.handle = nil
        }
    }

    private func rotateIfNeeded() {
        guard bytesWritten > maxBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotated)
        do {
            try fm.moveItem(at: url, to: rotated)
            bytesWritten = 0
        } catch {
            log.error("Failed to rotate event log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
