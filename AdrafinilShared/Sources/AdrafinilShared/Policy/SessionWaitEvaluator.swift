import Foundation

/// Decides what to do with Claude Code session holds while their sessions wait for the user
/// (issue #20): a question, a plan approval, or a permission prompt fires no end hook, so without
/// this the hold stands until the CPU-idle sweep — ~48 minutes of blocked sleep in the report.
///
/// The waiting signal is `ClaudeSessionStatus` (the session's own status file); the policy is the
/// user's `AgentWaitingPolicy`. The evaluator is the pure, unit-tested core in the style of
/// `IdleReleaseEvaluator`: it holds the cross-sweep bookkeeping (which holds are parked, and what
/// their expiry looked like before), while `SessionStatusMonitor` supplies the real file reads,
/// process probes, and the timer, and the daemon executes the returned actions.
///
/// A *parked* hold is one this evaluator acted on for a wait that hasn't resolved: under `.grace`
/// it carries a grace TTL (and may since have been released by TTL expiry); under `.sleep` it was
/// released outright. Parking is remembered so the moment the session turns busy again — answered
/// at the keyboard, from a phone, or auto-continued by a timeout — the hold is restored or
/// re-acquired, protecting the resumed turn that no hook announces.
public struct SessionWaitEvaluator: Sendable {
    public struct Config: Sendable {
        public var policy: AgentWaitingPolicy
        public var graceSeconds: TimeInterval

        public init(policy: AgentWaitingPolicy, graceSeconds: TimeInterval) {
            self.policy = policy
            self.graceSeconds = graceSeconds
        }
    }

    public enum Action: Sendable, Equatable {
        /// Stamp or clear the hold's `waitingFor` mark (UI only; every policy emits these).
        case setWaitingFor(key: String, label: String?)
        /// Arm the grace TTL on a live hold (`.grace`). Already min'd with any existing expiry.
        case park(key: String, expiresAt: Date)
        /// Release the hold now (`.sleep`).
        case release(key: String)
        /// Put a live hold's pre-park expiry back — its wait resolved.
        case restore(key: String, expiry: Date?)
        /// Re-acquire a hold that was fully released while its session waited (grace TTL ran out,
        /// or `.sleep` policy) — the session is busy again and the resumed turn needs protection.
        case reacquire(Assertion)
    }

    private struct Parked {
        var assertion: Assertion
        var originalExpiry: Date?
    }

    /// Holds acted on for a still-unresolved wait, by assertion key.
    private var parked: [String: Parked] = [:]
    /// Keys currently marked as waiting in the registry, with the label last set — so marks are
    /// emitted on change, not every sweep.
    private var waitingMarks: [String: String] = [:]

    public init() {}

    /// Whether any parked wait is outstanding. The monitor keeps sweeping while true even with
    /// nothing blocking — a released hold's session must still be seen turning busy.
    public var hasParked: Bool {
        !parked.isEmpty
    }

    private static let keyPrefix = "\(AgentKind.claudeCode.rawValue):"

    /// One sweep. `assertions` is the live registry snapshot, `statuses` every parsed status file.
    /// Holds whose key has no matching session (sub-agent ids, background-shell holds, other
    /// agents, manual holds) are left strictly alone.
    public mutating func evaluate(
        assertions: [Assertion],
        statuses: [ClaudeSessionStatus],
        now: Date,
        config: Config,
        pidAlive: (pid_t) -> Bool,
    ) -> [Action] {
        var actions: [Action] = []
        let byKey = Dictionary(assertions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for assertion in assertions {
            guard let sessionID = Self.sessionID(ofKey: assertion.key), assertion.origin == .hook else { continue }
            guard let status = ClaudeSessionStatus.best(forSession: sessionID, in: statuses, pidAlive: pidAlive) else {
                // No live status (file gone, custom config dir, pid dead): stand down from
                // anything this evaluator did and leave the hold to the normal nets.
                if let entry = parked.removeValue(forKey: assertion.key) {
                    actions.append(.restore(key: assertion.key, expiry: entry.originalExpiry))
                }
                clearMark(forKey: assertion.key, into: &actions)
                continue
            }

            switch status.activity {
            case .waiting:
                setMark(forKey: assertion.key, label: status.waitingFor ?? "input needed", into: &actions)
                guard parked[assertion.key] == nil else { break }
                switch config.policy {
                case .keepAwake:
                    break
                case .grace:
                    let graceExpiry = now.addingTimeInterval(config.graceSeconds)
                    parked[assertion.key] = Parked(assertion: assertion, originalExpiry: assertion.expiresAt)
                    actions.append(.park(key: assertion.key, expiresAt: min(assertion.expiresAt ?? .distantFuture, graceExpiry)))
                case .sleep:
                    parked[assertion.key] = Parked(assertion: assertion, originalExpiry: assertion.expiresAt)
                    actions.append(.release(key: assertion.key))
                }
            case .busy, .idle:
                // The wait resolved (busy), or the turn ended entirely (idle — the Stop hook
                // releases the hold on its own). Either way, put the expiry back and stand down.
                clearMark(forKey: assertion.key, into: &actions)
                if let entry = parked.removeValue(forKey: assertion.key) {
                    actions.append(.restore(key: assertion.key, expiry: entry.originalExpiry))
                }
            }
        }

        // Parked holds that no longer exist: released by the `.sleep` policy, or the grace TTL ran
        // out and the idle sweep collected it. Wait for the session to move.
        for (key, entry) in parked where byKey[key] == nil {
            guard let sessionID = Self.sessionID(ofKey: key),
                  let status = ClaudeSessionStatus.best(forSession: sessionID, in: statuses, pidAlive: pidAlive) else {
                parked.removeValue(forKey: key) // session (or its file) is gone — nothing to resume
                continue
            }
            switch status.activity {
            case .waiting:
                break // still parked; the Mac may sleep meanwhile
            case .busy:
                // The turn resumed with no hook to announce it — re-acquire the remembered hold,
                // with its pre-park expiry and no stale waiting mark.
                parked.removeValue(forKey: key)
                var assertion = entry.assertion
                assertion.expiresAt = entry.originalExpiry
                assertion.waitingFor = nil
                assertion.lastActivityAt = now
                actions.append(.reacquire(assertion))
            case .idle:
                parked.removeValue(forKey: key) // turn is over; nothing to protect
            }
        }

        // Marks for keys that vanished from the registry (any release path) need no clearing
        // action — the mark lives on the assertion and died with it. Just forget the bookkeeping.
        waitingMarks = waitingMarks.filter { byKey[$0.key] != nil }

        return actions
    }

    /// The session id a per-turn Claude Code hold is keyed on, or nil for every other key shape.
    /// (Sub-agent and background-shell holds share the prefix but their suffixes never match a
    /// session file's `sessionId`, so they fall out at the status lookup instead.)
    private static func sessionID(ofKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let suffix = String(key.dropFirst(keyPrefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    private mutating func setMark(forKey key: String, label: String, into actions: inout [Action]) {
        guard waitingMarks[key] != label else { return }
        waitingMarks[key] = label
        actions.append(.setWaitingFor(key: key, label: label))
    }

    private mutating func clearMark(forKey key: String, into actions: inout [Action]) {
        guard waitingMarks.removeValue(forKey: key) != nil else { return }
        actions.append(.setWaitingFor(key: key, label: nil))
    }
}
