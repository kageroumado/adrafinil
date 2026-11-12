import AdrafinilShared
import Darwin
import Foundation
import OSLog

/// Watches Claude Code's session status files (`~/.claude/sessions/<pid>.json`, plus the `sessions/`
/// of any custom `CLAUDE_CONFIG_DIR` profile learned from hooks) so a session that
/// has stopped mid-turn to wait for the user — a question, a plan approval, a permission prompt —
/// is handled by the user's `AgentWaitingPolicy` instead of standing until the CPU-idle sweep
/// (issue #20). See `ClaudeSessionStatus` for the file, `SessionWaitEvaluator` for the decisions;
/// this supplies the file reads, the process probe, and the timer, and hands actions to the daemon.
///
/// Polling, not file watching, on purpose: Claude Code rewrites the files in place (no rename), so
/// a directory kqueue never fires for status flips — and the poll is gated exactly like the other
/// monitors: it runs while an assertion is held (`isBlocking`), plus while a parked wait is
/// outstanding (a hold this policy released must still see its session turn busy again). With
/// nothing held and nothing parked there is no timer and no wakeups.
@MainActor
final class SessionStatusMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "SessionStatus")

    var policy: AgentWaitingPolicy = .grace
    var graceSeconds: TimeInterval = 600

    var assertionSource: (() async -> [Assertion])?
    /// Receives each sweep's decisions, in order. The daemon executes them against the registry.
    var onActions: (([SessionWaitEvaluator.Action]) async -> Void)?

    /// The directories to read: `~/.claude/sessions` plus learned profile directories. The daemon
    /// registers a profile when a Claude Code hook's `acquire` reports its `CLAUDE_CONFIG_DIR`.
    /// Not persisted — after a daemon restart a profile is re-learned on its next acquire.
    private(set) var directories = ClaudeSessionDirectories()

    /// Registers a `CLAUDE_CONFIG_DIR` reported by a Claude Code hook. Invalid paths (outside the
    /// home dir, no `sessions/`, the default dir) are ignored; the set is capped.
    func registerClaudeConfigDir(_ raw: String?) {
        guard let raw else { return }
        if directories.register(raw), let path = directories.learned.last {
            log.notice("watching Claude Code profile sessions under '\(path, privacy: .public)'")
        }
    }

    private var evaluator = SessionWaitEvaluator()
    private var timer: Timer?

    /// Mirrors the registry's blocking state, like `IdleMonitor.isBlocking`. Re-gates the timer on
    /// every flip — but unlike the idle monitor, a parked wait keeps the timer alive through the
    /// blocking→idle edge its own release just caused.
    var isBlocking: Bool = false {
        didSet {
            guard isBlocking != oldValue else { return }
            updateTimer()
        }
    }

    /// A sweep every 10 s: fast enough that a wait is parked well inside any sensible grace
    /// window and a phone answer re-arms the hold promptly, cheap enough to not matter while the
    /// Mac is awake anyway (a handful of sub-kilobyte reads).
    private static let sweepInterval: TimeInterval = 10

    func start() {
        updateTimer()
    }

    private var timerNeeded: Bool {
        isBlocking || evaluator.hasParked
    }

    private func updateTimer() {
        if timerNeeded, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.sweep() }
            }
        } else if !timerNeeded, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    func sweep() async {
        guard let assertions = await assertionSource?() else { return }
        let actions = evaluator.evaluate(
            assertions: assertions,
            statuses: readStatuses(),
            now: Date(),
            config: .init(policy: policy, graceSeconds: graceSeconds),
            pidAlive: { kill($0, 0) == 0 || errno == EPERM },
        )
        // A sweep can park the last hold (dropping `isBlocking`) or drop the last parked entry —
        // either way the timer's condition may have changed.
        defer { updateTimer() }
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
            case let .park(key, expiresAt):
                log.notice("session waiting — grace TTL until \(expiresAt, privacy: .public) on '\(key, privacy: .public)'")
            case let .release(key):
                log.notice("session waiting — releasing '\(key, privacy: .public)' (policy: sleep)")
            case let .restore(key, _):
                log.notice("session resumed — restoring '\(key, privacy: .public)'")
            case let .reacquire(assertion):
                log.notice("session resumed after its hold was released — re-acquiring '\(assertion.key, privacy: .public)'")
            case .setWaitingFor:
                break
            }
        }
        await onActions?(actions)
    }

    /// Every parseable status file across the sessions directories. A missing directory (Claude
    /// Code absent or never run) reads as no sessions, which disables the whole policy gracefully.
    private func readStatuses() -> [ClaudeSessionStatus] {
        directories.sessionsDirectories.flatMap { directory -> [ClaudeSessionStatus] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.compactMap { name in
                guard ClaudeSessionStatus.isStatusFilename(name),
                      let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return ClaudeSessionStatus.parse(data)
            }
        }
    }
}
