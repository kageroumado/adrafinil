import Foundation

/// Policy and helpers for *agent holds* — explicit, reasoned, time-boxed sleep blocks placed by an
/// agent via `adrafinil hold` or the MCP server. Distinct from editor-hook assertions: they live in
/// the `hold:` key namespace, carry `origin == .manual`, and are governed by their TTL rather than
/// the idle policy. Pure and testable; the daemon is the authority that applies it.
public enum ManualHold {
    /// TTL used when a hold is requested without an explicit duration.
    public static let defaultTTL: TimeInterval = 60 * 60

    /// The `key` prefix that marks an assertion as an agent hold.
    public static let keyPrefix = "hold:"

    /// Tool label stored on a hold that didn't name its originating agent.
    public static let defaultTool = "manual"

    public static func isHoldKey(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix)
    }

    /// The registry key for a hook-driven session hold. Hook sessions are keyed `<tool>:<sessionID>`;
    /// an id that is already a full agent-hold key (`hold:…`) is used verbatim, so releasing an
    /// MCP/CLI-placed hold by its key targets it directly. Acquire and release derive the key
    /// identically, which is what guarantees a session's `UserPromptSubmit` acquire and its matching
    /// `Stop` release land on the same key — the property the Codex (and Claude Code) hook model relies
    /// on for per-turn bracketing.
    public static func sessionKey(tool: String, sessionID: String) -> String {
        isHoldKey(sessionID) ? sessionID : "\(tool):\(sessionID)"
    }

    /// A fresh hold key: `hold:` + 8 lowercase hex chars. Short enough to echo back to an agent,
    /// unique enough to never collide in practice.
    public static func newKey() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return keyPrefix + hex
    }

    /// Clamps a requested TTL into `[1s, cap]`, defaulting to `defaultTTL` when none was given.
    /// The cap (the user-configurable `manualHoldMaxHours`) is the hard ceiling: a forgetful agent
    /// can never pin the Mac awake longer than this.
    public static func clampTTL(_ requested: TimeInterval?, capHours: Double) -> TimeInterval {
        let cap = max(1, capHours * 3_600)
        let wanted = requested ?? defaultTTL
        return min(max(wanted, 1), cap)
    }
}

/// Parses a human duration string into seconds. Accepts a bare number (seconds), a single unit
/// (`30s`, `45m`, `2h`, `1d`), or a compound (`1h30m`, `90m`, `2h15m30s`). Returns nil on garbage so
/// callers can surface a usage error rather than silently mis-holding.
public enum DurationParser {
    public static func seconds(from input: String) -> TimeInterval? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        // Bare number → seconds. "inf"/"nan" parse as TimeInterval but are not durations.
        if let bare = TimeInterval(s) { return (bare.isFinite && bare >= 0) ? bare : nil }

        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        var total: TimeInterval = 0
        var number = ""
        var sawUnit = false

        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else if let mult = units[ch] {
                guard !number.isEmpty, let value = TimeInterval(number) else { return nil }
                total += value * mult
                number = ""
                sawUnit = true
            } else {
                return nil
            }
        }
        // Trailing digits with no unit (e.g. "1h30") are ambiguous — reject.
        guard sawUnit, number.isEmpty else { return nil }
        return total
    }
}
