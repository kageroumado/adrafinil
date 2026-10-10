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
///     deadline. The daemon's CPU-idle net can't stand in for one: it measures the *agent's* process
///     tree, which says nothing about the task — busy with other turns it never looks idle, and
///     parked at the prompt while a quiet task runs it looks idle at once — so background holds are
///     exempt from it (`isBackgroundKey`). Hence a TTL —
///     `requestedTTL` (the installed hook passes `--ttl <ceiling>`), else `defaultTTLSeconds` — which
///     the daemon further clamps to the live `manualHoldMaxHours` (`ManualHold.clampExpiry`). The
///     installed command deliberately requests the ceiling so the *effective* TTL always tracks the
///     user's configured max-hold, rather than a value baked in at install time that drifts when they
///     change the cap.
///   - **Per-invocation key.** Each background command holds independently (`bg-<uniqueID>` in the
///     session slot of `<tool>:<key>`), so two overlapping background tasks don't share — and thus
///     can't prematurely release — one another's hold.
///
/// **Monitors.** Claude Code's Monitor tool is the same shape of problem: it starts a watch that
/// outlives the turn, wakes the agent with each event, and fires no hook when it ends. Unlike a
/// background command it carries its own deadline (`timeout_ms`), so its hold is sized to that
/// instead of the ceiling — a watch the agent forgot about can't keep the Mac up for hours.
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

    /// Slack added to a Monitor's own deadline. A monitor that reaches its deadline wakes the agent,
    /// which often re-arms it straight away; the margin keeps the Mac awake across that handoff
    /// instead of letting the hold lapse in the seconds between the old watch and the new one.
    public static let monitorGraceSeconds: TimeInterval = 60

    /// Whether `key` is a background-task hold (`<tool>:bg-<id>`). Such holds are exempt from the
    /// CPU-idle release: the agent that started the task is *expected* to sit idle while it runs —
    /// a `tail -f`, or a Monitor polling every 30 s, barely registers — so only the TTL (and the
    /// dead-process net) may end them. See `IdleReleaseEvaluator`.
    public static func isBackgroundKey(_ key: String) -> Bool {
        guard let colon = key.firstIndex(of: ":") else { return false }
        return key[key.index(after: colon)...].hasPrefix(keyInfix)
    }

    /// The decision for `acquire --if-background`, given the hook's `PreToolUse` stdin payload.
    ///
    /// Returns `nil` when the tool call starts no background work — the common path (every foreground
    /// Bash call, and every other tool's `PreToolUse`), where the CLI must place no hold and exit 0.
    /// Returns a `Plan` for a `run_in_background` Bash command or a Monitor: a per-invocation `bg-` key
    /// (from `uniqueID`; production passes a fresh id, tests a fixed one) and the TTL.
    ///
    /// A background command's TTL is `requestedTTL`, else `defaultTTLSeconds` — it has no deadline of
    /// its own. A Monitor does: Claude Code kills it at `timeout_ms`, so the hold lasts that long plus
    /// `monitorGraceSeconds`, capped by `requestedTTL`. A persistent Monitor has no deadline and is
    /// treated like a background command.
    public static func plan(payload: Data, tool: String, requestedTTL: TimeInterval?, uniqueID: String) -> Plan? {
        let ceiling = requestedTTL ?? defaultTTLSeconds
        let ttl: TimeInterval
        switch HookPayload.monitorDeadline(in: payload) {
        case let .seconds(seconds):
            ttl = min(seconds + monitorGraceSeconds, ceiling)
        case .persistent:
            ttl = ceiling
        case nil:
            guard HookPayload.runInBackground(in: payload) else { return nil }
            ttl = ceiling
        }
        return Plan(key: ManualHold.sessionKey(tool: tool, sessionID: keyInfix + uniqueID), ttl: ttl)
    }

    /// A fresh per-invocation id: 8 lowercase hex chars, matching `ManualHold.newKey`'s brevity.
    public static func freshID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
