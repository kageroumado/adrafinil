import Foundation

/// One Claude Code session's live activity state, read from its status file.
///
/// Every top-level Claude Code session maintains `~/.claude/sessions/<pid>.json` with, among
/// other fields, `status: "busy" | "idle" | "waiting"` and a `waitingFor` label while a dialog is
/// open ("approve Bash", "input needed", …). The status is computed from the session's full
/// dialog stack — questions, plan approvals, permission prompts, elicitations — and rewritten by
/// the same code path that resolves a dialog, whichever way it resolves: an answer at the
/// keyboard, an answer from a phone over Remote Control, or an `askUserQuestionTimeout` /
/// `dialogExpiry` auto-continue. That makes it the one deterministic channel for "this agent is
/// waiting on its user" — including the prompt kinds that fire no hook at all.
///
/// The format is Claude Code internals (it backs `claude ps` and teammates; stable since March
/// 2026, fields only accreted), so parsing is strictly defensive: anything unrecognized reads as
/// "no status", and every consumer must degrade to Adrafinil's existing nets when it does.
/// Sessions started with a non-default `CLAUDE_CONFIG_DIR` write elsewhere and simply aren't seen.
///
/// The `<pid>.<hash>.key` files in the same directory are messaging-socket auth material — the
/// filename filter here must never match them, and nothing may read them.
public struct ClaudeSessionStatus: Sendable, Equatable {
    public enum Activity: String, Sendable {
        case busy
        case idle
        case waiting
    }

    public let pid: pid_t
    public let sessionID: String
    public let activity: Activity
    /// What the session is waiting on, while `activity == .waiting` ("approve Bash",
    /// "input needed", "dialog open", …). Optional even then — older builds omit it.
    public let waitingFor: String?
    /// When `activity` last changed, from the file's millisecond-epoch `statusUpdatedAt`.
    public let statusUpdatedAt: Date?

    public init(pid: pid_t, sessionID: String, activity: Activity, waitingFor: String? = nil, statusUpdatedAt: Date? = nil) {
        self.pid = pid
        self.sessionID = sessionID
        self.activity = activity
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// The default status directory. Claude Code writes under its config home; the daemon has no
    /// view of a user's shell environment, so a custom `CLAUDE_CONFIG_DIR` is out of scope.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Whether `filename` is a session status file (`<pid>.json`, strictly). Anchored the same way
    /// as Claude Code's own reader, so the `.key` auth files and anything else are never touched.
    public static func isStatusFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".json") else { return false }
        let stem = filename.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy(\.isNumber)
    }

    /// Parses one status file. Returns nil when the bytes aren't a JSON object carrying a positive
    /// integer `pid`, a non-empty string `sessionId`, and a `status` in the known set — an unknown
    /// status string means a newer Claude Code changed the vocabulary, and guessing would be worse
    /// than falling back to the CPU nets.
    public static func parse(_ data: Data) -> ClaudeSessionStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = obj["pid"] as? Int, pidValue > 0,
              let sessionID = obj["sessionId"] as? String, !sessionID.isEmpty,
              let statusString = obj["status"] as? String,
              let activity = Activity(rawValue: statusString) else { return nil }
        let waitingFor = (obj["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updatedMillis = (obj["statusUpdatedAt"] as? Double) ?? (obj["updatedAt"] as? Double)
        return ClaudeSessionStatus(
            pid: pid_t(pidValue),
            sessionID: sessionID,
            activity: activity,
            waitingFor: waitingFor,
            statusUpdatedAt: updatedMillis.map { Date(timeIntervalSince1970: $0 / 1_000) },
        )
    }

    /// The authoritative status for `sessionID` among possibly-several files claiming it. A crashed
    /// session leaves its file behind (cleanup never ran), and a `--resume` registers the same
    /// session id under a new pid — so dead pids are discarded, and among live ones the freshest
    /// `statusUpdatedAt` wins.
    public static func best(
        forSession sessionID: String,
        in statuses: [ClaudeSessionStatus],
        pidAlive: (pid_t) -> Bool,
    ) -> ClaudeSessionStatus? {
        statuses
            .filter { $0.sessionID == sessionID && pidAlive($0.pid) }
            .max { ($0.statusUpdatedAt ?? .distantPast) < ($1.statusUpdatedAt ?? .distantPast) }
    }
}
