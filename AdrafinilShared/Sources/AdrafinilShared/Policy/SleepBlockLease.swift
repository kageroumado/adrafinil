import Foundation

public struct SleepBlockLease: Sendable {
    public private(set) var expiresAt: Date?

    public init() {
        expiresAt = nil
    }

    public mutating func renew(now: Date, duration: TimeInterval) {
        let proposedDeadline = now.addingTimeInterval(duration)
        if let expiresAt, expiresAt >= proposedDeadline {
            return
        } else {
            expiresAt = proposedDeadline
        }
    }

    public mutating func clear() {
        expiresAt = nil
    }

    public mutating func expireIfNeeded(now: Date) -> Bool {
        guard let expiresAt, now >= expiresAt else { return false }
        clear()
        return true
    }
}
