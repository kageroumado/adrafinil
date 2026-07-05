import Foundation

/// Policy for the opt-in *background-shell* keep-awake (issue #7 Part 2). Part 1 covers agents and
/// sub-agents whose work brackets a hook pair; the remaining gap is a shell command an agent launches
/// with `run_in_background: true` (Claude Code's Bash tool). Such a command keeps running after the
/// turn's `Stop`, and **neither the parent nor any sub-agent fires a completion hook for it** — so
/// there is no symmetric release, only the `PreToolUse` that starts it.
///
/// Two consequences shape this design:
///
///   - **TTL-bounded, not idle-released.** With no end hook, the hold can only be released by a
///     deadline. The daemon's CPU-idle net won't do it either: while the agent keeps serving other
///     turns its process tree isn't idle, so the hold would linger indefinitely. Hence a TTL —
///     `requestedTTL` (the installed hook passes `--ttl <ceiling>`), else `defaultTTLSeconds` — which
///     the daemon further clamps to the live `manualHoldMaxHours` (`ManualHold.clampExpiry`). The
///     installed command deliberately requests the ceiling so the *effective* TTL always tracks the
///     user's configured max-hold, rather than a value baked in at install time that drifts when they
///     change the cap.
///   - **Per-invocation key.** Each background command holds independently (`bg-<uniqueID>` in the
///     session slot of `<tool>:<key>`), so two overlapping background tasks don't share — and thus
///     can't prematurely release — one another's hold.
///
/// This type is the pure, testable decision; the `acquire --if-background` CLI command reads the
/// stdin payload and the owning PID around it, and the daemon applies and caps the resulting hold.
///
/// **Claude Code only.** Codex has no equivalent clean pre-tool boolean: its shell tool uses an
/// `exec_command`/`write_stdin` PTY model with a `yield_time_ms` background yield, not a single
/// `run_in_background` flag on one tool call, so there's no reliable `PreToolUse` signal to key on.
/// Codex background-shell keep-awake is a follow-up; the shape is installed only for Claude Code.
public enum BackgroundBashHold {
    /// The marker that namespaces a background-shell hold within the session slot of its key, so it
    /// reads as `<tool>:bg-<uniqueID>` and never collides with a real per-turn `<tool>:<session_id>`.
    public static let keyInfix = "bg-"

    /// TTL requested when the hook command carries no explicit `--ttl`. Set to the CLI's 24h absolute
    /// ceiling so the daemon's live `manualHoldMaxHours` clamp is what actually governs the duration.
    public static let defaultTTLSeconds: TimeInterval = 24 * 60 * 60

    /// A hold to place, or the absence of one.
    public struct Plan: Equatable {
        /// The registry key, `<tool>:bg-<uniqueID>` — unique per invocation.
        public let key: String
        /// The requested TTL in seconds; the daemon clamps it down to `manualHoldMaxHours`.
        public let ttl: TimeInterval

        public init(key: String, ttl: TimeInterval) {
            self.key = key
            self.ttl = ttl
        }
    }

    /// The decision for `acquire --if-background`, given the hook's `PreToolUse` stdin payload.
    ///
    /// Returns `nil` when the tool call is not `run_in_background` — the common path (every foreground
    /// Bash call, and every non-Bash `PreToolUse`), where the CLI must place no hold and exit 0.
    /// Returns a `Plan` when it is: a per-invocation `bg-` key (from `uniqueID`; production passes a
    /// fresh id, tests a fixed one) and the TTL (`requestedTTL`, else `defaultTTLSeconds`).
    public static func plan(payload: Data, tool: String, requestedTTL: TimeInterval?, uniqueID: String) -> Plan? {
        guard HookPayload.runInBackground(in: payload) else { return nil }
        return Plan(
            key: ManualHold.sessionKey(tool: tool, sessionID: keyInfix + uniqueID),
            ttl: requestedTTL ?? defaultTTLSeconds,
        )
    }

    /// A fresh per-invocation id: 8 lowercase hex chars, matching `ManualHold.newKey`'s brevity.
    public static func freshID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
