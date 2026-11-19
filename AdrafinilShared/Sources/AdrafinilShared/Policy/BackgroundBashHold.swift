import Foundation

/// Policy for the opt-in *background-shell* keep-awake (issue #7 Part 2). A `run_in_background` Bash
/// command or a Monitor outlives the turn's `Stop` and fires no completion hook, so its hold is placed
/// on `PreToolUse` and bound to the task's shell on `PostToolUse` (`startedTask`, `binding`). The hold
/// then ends when that shell exits; the TTL is only the fallback when the shell can't be found.
///
/// Consequences:
///
///   - **Not idle-released.** The CPU-idle net measures the *agent's* process tree, which says nothing
///     about the task, so background holds are exempt (`isBackgroundKey`). The dead-process net and the
///     TTL end them. The TTL is `requestedTTL` (the hook passes the 24h ceiling) else
///     `defaultTTLSeconds`, which the daemon clamps to the live `manualHoldMaxHours`.
///   - **Per-call key.** The `bg-<id>` derives from `tool_use_id`, identical on `PreToolUse` and
///     `PostToolUse`, so overlapping tasks never share one hold.
///
/// **Monitors.** A Monitor carries its own deadline (`timeout_ms`), so its hold is sized to that
/// instead. Its output goes over a unix socket, so it is never bound to a shell.
///
/// This type is the pure decision; the `acquire --if-background` and `--bind-background` CLI commands
/// read the stdin payload and the process tree around it.
///
/// **Claude Code only.** Codex has no equivalent clean pre-tool boolean: its shell tool uses an
/// `exec_command`/`write_stdin` PTY model with a `yield_time_ms` background yield, not a single
/// `run_in_background` flag on one tool call, so there's no reliable `PreToolUse` signal to key on.
/// Codex background-shell keep-awake is a follow-up; the shape is installed only for Claude Code.
public enum BackgroundBashHold {
    /// The marker that namespaces a background-shell hold within the session slot of its key, so it
    /// reads as `<tool>:bg-<id>` and never collides with a real per-turn `<tool>:<session_id>`.
    public static let keyInfix = "bg-"

    /// TTL requested when the hook command carries no explicit `--ttl`. Set to the CLI's 24h absolute
    /// ceiling so the daemon's live `manualHoldMaxHours` clamp is what actually governs the duration.
    public static let defaultTTLSeconds: TimeInterval = 24 * 60 * 60

    /// A hold to place, or the absence of one.
    public struct Plan: Equatable {
        /// The registry key, `<tool>:bg-<id>` — unique per tool call.
        public let key: String
        /// The requested TTL in seconds; the daemon clamps it down to `manualHoldMaxHours`.
        public let ttl: TimeInterval

        public init(key: String, ttl: TimeInterval) {
            self.key = key
            self.ttl = ttl
        }
    }

    /// A background shell a `PostToolUse` Bash call started, and the hold its `PreToolUse` placed.
    public struct BackgroundTask: Equatable {
        /// The hold's key — the same one `plan` derived on the `PreToolUse`.
        public let key: String
        /// The parent session, which names the task's output directory.
        public let sessionID: String
        /// The `backgroundTaskId` from the Bash result, which names the task's output file.
        public let taskID: String
        /// The TTL to re-assert with the bind, matching what `plan` requested.
        public let ttl: TimeInterval

        public init(key: String, sessionID: String, taskID: String, ttl: TimeInterval) {
            self.key = key
            self.sessionID = sessionID
            self.taskID = taskID
            self.ttl = ttl
        }
    }

    /// The outcome of searching the agent's process tree for a task's shell.
    public struct ShellSearch: Equatable {
        /// The topmost process holding the task's output file, or nil when none does.
        public let pid: pid_t?
        /// Whether the caller itself is a descendant of the agent in this snapshot. The hook always
        /// runs under the agent, so false means the snapshot is unreliable and a nil `pid` proves nothing.
        public let snapshotIncludesCaller: Bool

        public init(pid: pid_t?, snapshotIncludesCaller: Bool) {
            self.pid = pid
            self.snapshotIncludesCaller = snapshotIncludesCaller
        }
    }

    /// What the `PostToolUse` bind does with a background task's hold.
    public enum TaskBinding: Equatable {
        /// The shell is alive: point the hold at its PID so the dead-process net ends it on exit.
        case bind(pid_t)
        /// The task already finished (its output file exists, its shell does not): end the hold now.
        case release
        /// Neither is visible: leave the hold to its TTL.
        case none
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
    /// Returns a `Plan` for a `run_in_background` Bash command or a Monitor: a `bg-` key and the TTL.
    /// The key derives from the payload's `tool_use_id`, so the `PostToolUse` bind finds it again;
    /// `uniqueID` is used only when the payload carries none.
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
        let id = HookPayload.toolUseID(in: payload).map(bindingID(toolUseID:)) ?? uniqueID
        return Plan(key: key(tool: tool, id: id), ttl: ttl)
    }

    /// The background task a `PostToolUse` Bash payload started, or nil when it started none — every
    /// foreground call, and every other tool. The key is derived exactly as `plan` derives it on the
    /// `PreToolUse`, so the bind addresses the hold that call placed.
    public static func startedTask(payload: Data, tool: String, requestedTTL: TimeInterval?) -> BackgroundTask? {
        guard let started = HookPayload.backgroundBashTask(in: payload),
              let sessionID = HookPayload.sessionID(in: payload) else { return nil }
        return BackgroundTask(
            key: key(tool: tool, id: bindingID(toolUseID: started.toolUseID)),
            sessionID: sessionID,
            taskID: started.taskID,
            ttl: requestedTTL ?? defaultTTLSeconds,
        )
    }

    /// The `bg-` id for a tool call: 8 lowercase hex digits of the 32-bit FNV-1a hash of its
    /// `tool_use_id`. A hash rather than `freshID()` because the `PreToolUse` and `PostToolUse` run in
    /// separate processes and must agree on it; FNV-1a is fixed by its definition, so it does.
    public static func bindingID(toolUseID: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in toolUseID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// A fresh per-invocation id: 8 lowercase hex chars, matching `ManualHold.newKey`'s brevity. Used
    /// only when a hook payload carries no `tool_use_id`.
    public static func freshID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    /// The registry key of a background hold with id `id`: `<tool>:bg-<id>`.
    public static func key(tool: String, id: String) -> String {
        ManualHold.sessionKey(tool: tool, sessionID: keyInfix + id)
    }

    /// The path suffix of a background task's output file, below Claude Code's per-cwd directory:
    /// `<session>/tasks/<taskID>.output`. Matched by suffix because the fd paths carry a prefix that
    /// varies with the temp root (`/private/tmp` for `/tmp`).
    public static func taskOutputSuffix(sessionID: String, taskID: String) -> String {
        "/\(sessionID)/tasks/\(taskID).output"
    }

    /// The directory Claude Code writes its task output under: `$CLAUDE_CODE_TMPDIR`, else `/tmp`.
    public static func taskTempRoot(environment: [String: String]) -> String {
        let override = environment["CLAUDE_CODE_TMPDIR"] ?? ""
        return override.isEmpty ? "/tmp" : override
    }

    /// Searches `root`'s descendants for the task's shell: the topmost process holding the output file
    /// on stdout or stderr, since commands the shell runs inherit those fds. Breadth-first, so the first
    /// match is the shallowest. Also reports whether `caller` appears in the same snapshot.
    ///
    /// - Parameters:
    ///   - caller: the calling process; the hook always runs under the agent, so it must be found.
    ///   - children: the parent-to-children map (`ProcessResolver.childMap()`).
    ///   - openPaths: the stdio vnode paths of a process (`ProcessResolver.stdioPaths(of:)`).
    public static func taskShellSearch(
        root: pid_t,
        caller: pid_t,
        suffix: String,
        children: [pid_t: [pid_t]],
        openPaths: (pid_t) -> [String],
    ) -> ShellSearch {
        var queue = children[root] ?? []
        var seen: Set<pid_t> = [root]
        var shell: pid_t?
        var next = 0
        while next < queue.count {
            let pid = queue[next]
            next += 1
            guard seen.insert(pid).inserted else { continue }
            if shell == nil, openPaths(pid).contains(where: { $0.hasSuffix(suffix) }) {
                shell = pid
            }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return ShellSearch(pid: shell, snapshotIncludesCaller: seen.contains(caller))
    }

    /// Whether the task's output file exists under any per-cwd directory,
    /// `<tempRoot>/claude-<uid>/<cwd-slug>/<session>/tasks/<task>.output`. The file outlives its shell,
    /// so its presence with no live shell signals a finished task.
    ///
    /// - Parameters:
    ///   - listDirectories: the entry names directly under a path (the per-cwd slugs).
    ///   - fileExists: whether a file exists at a full path.
    public static func taskOutputExists(
        sessionID: String,
        taskID: String,
        tempRoot: String,
        uid: uid_t,
        listDirectories: (String) -> [String],
        fileExists: (String) -> Bool,
    ) -> Bool {
        let base = "\(tempRoot)/claude-\(uid)"
        let suffix = taskOutputSuffix(sessionID: sessionID, taskID: taskID)
        return listDirectories(base).contains { fileExists(base + "/" + $0 + suffix) }
    }

    /// The `PostToolUse` decision. Release needs proof the snapshot is real: a failed or empty process
    /// tree finds no shell too, and must fall back to the TTL instead of ending a live task.
    public static func binding(search: ShellSearch, outputExists: Bool) -> TaskBinding {
        if let pid = search.pid { return .bind(pid) }
        guard search.snapshotIncludesCaller, outputExists else { return .none }
        return .release
    }
}
