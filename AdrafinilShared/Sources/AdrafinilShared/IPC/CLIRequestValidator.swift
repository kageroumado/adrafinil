import Foundation

/// Validation for requests arriving over the CLI socket. The socket deliberately accepts any
/// same-user caller (that's how agent hooks reach the daemon), so its inputs are untrusted:
/// fields get hard length caps before they are stored, persisted, and broadcast, and the key
/// namespaces the daemon mints itself are off-limits to external acquires.
public enum CLIRequestValidator {
    public static let maxKeyLength = 256
    public static let maxToolLength = 64
    public static let maxReasonLength = 1_024

    /// Key prefix of auto-acquired (process-sniffed) assertions, minted only by the daemon.
    public static let sniffedKeyPrefix = "sniffed:"

    /// Namespaces the daemon mints itself. An external `acquire` planting a key here would
    /// confuse hold/sniff bookkeeping (e.g. `ManualHold.isHoldKey` checks, per-row release UI).
    public static let reservedKeyPrefixes = [ManualHold.keyPrefix, sniffedKeyPrefix]

    /// Why an `acquire` was rejected, with the message sent back over the wire.
    public static func acquireRejection(key: String, tool: String) -> String? {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "acquire requires a non-empty key"
        }
        if key.count > maxKeyLength {
            return "key exceeds \(maxKeyLength) characters"
        }
        if tool.count > maxToolLength {
            return "tool exceeds \(maxToolLength) characters"
        }
        if let reserved = reservedKeyPrefixes.first(where: { key.hasPrefix($0) }) {
            return "the '\(reserved)' key namespace is reserved"
        }
        return nil
    }

    /// Reasons are advisory display strings — truncate rather than reject.
    public static func clampedReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        return reason.count > maxReasonLength ? String(reason.prefix(maxReasonLength)) : reason
    }

    /// TTLs are hard deadlines chosen by the caller. Non-finite or non-positive values are
    /// dropped (the idle sweep still governs the assertion — and an infinity would make
    /// JSONEncoder throw when the assertion is persisted); anything beyond the daemon's 24-hour
    /// max-age backstop is capped to it, since a longer TTL could never fire anyway.
    public static func clampedTTL(_ ttl: TimeInterval?) -> TimeInterval? {
        guard let ttl, ttl.isFinite, ttl > 0 else { return nil }
        return min(ttl, 24 * 3_600)
    }
}
