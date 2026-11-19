import AdrafinilShared
import Foundation
import OSLog

private let cliLog = Logger(subsystem: AdrafinilConstants.appBundleID, category: "CLI")

enum AcquireCommand {
    /// `acquire`/`release` run inside agent hooks, where a nonzero exit is interpreted by the
    /// agent — Claude Code treats a `UserPromptSubmit` hook exiting 2 as "block and erase the
    /// user's prompt". A missed acquire costs at most one un-protected turn; a blocked prompt
    /// destroys the user's input. So every failure here warns on stderr and exits 0. Exit 2 is
    /// reserved for a human at a TTY misusing the command.
    static func hookFailure(_ message: String) -> Never {
        FileHandle.standardError.write(Data("adrafinil: \(message)\n".utf8))
        exit(isatty(FileHandle.standardInput.fileDescriptor) != 0 ? 2 : 0)
    }

    /// The PID the daemon should watch for a session-keyed hold, in trust order:
    ///
    /// 1. `--pid` from the hook itself. Pi's extension runs in-process in the host, so the
    ///    `process.pid` it passes is the agent's own PID — authoritative regardless of how the
    ///    agent is packaged. Verified alive first, so a stale value can't bind the hold to a
    ///    recycled PID (the daemon would then instantly dead-process-release a live turn).
    /// 2. The executable-path parent walk — the normal case for agents that run as their own binary.
    ///    getppid() is the shell (/bin/sh) that runs the hook command — it exits as soon as
    ///    adrafinil returns, so the walk continues to the first ancestor whose binary name matches
    ///    a known agent.
    /// 3. For Pi only: an argv-based walk, authorized by the `AI_AGENT=pi`/`PI_CODING_AGENT=true`
    ///    markers Pi sets in its own environment (and this CLI therefore inherits). Covers an
    ///    installed extension that predates `--pid`: a Node-hosted Pi's executable path is Node's,
    ///    so step 2 returns -1 and the hold had no PID for the dead-process and CPU-idle nets
    ///    (issue #26). The marker gate keeps the walk from binding an arbitrary Node ancestor of a
    ///    non-Pi invocation.
    ///
    /// Returns `-1` when nothing resolves — the daemon then must not process-watch (safer than
    /// watching the wrong PID).
    static func resolveOwningPID(hookPID: pid_t?, tool: String) -> pid_t {
        if let hookPID {
            if kill(hookPID, 0) == 0 || errno == EPERM { return hookPID }
            FileHandle.standardError.write(Data("adrafinil: --pid \(hookPID) is not alive — falling back to process-tree resolution\n".utf8))
        }
        let walked = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
        if walked > 0 { return walked }
        if tool == AgentKind.pi.rawValue, AgentKind.environmentMarksPi(ProcessInfo.processInfo.environment) {
            return ProcessResolver.owningAgentPID(argvMatches: AgentKind.argvIsPi(_:))
        }
        return -1
    }

    /// The `PostToolUse`(Bash) hook behind `--bind-background`: re-points a background command's hold
    /// from the agent PID to its shell, so the dead-process net ends it when the shell exits. Other
    /// calls return after the stdin parse, before any process-tree or daemon work.
    static func bindBackground(tool: String, requestedTTL: TimeInterval?) -> Never {
        let payload = CLIStdin.payload() ?? Data()
        guard let task = BackgroundBashHold.startedTask(payload: payload, tool: tool, requestedTTL: requestedTTL) else {
            exit(0)
        }
        let suffix = BackgroundBashHold.taskOutputSuffix(sessionID: task.sessionID, taskID: task.taskID)
        let agentPID = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
        // Without the agent there is no tree to search, so "no shell" can't be read as "finished".
        guard agentPID > 0 else {
            cliLog.notice("bind \(task.key, privacy: .public) — no agent process matched; leaving the hold to its TTL")
            exit(0)
        }
        let search = BackgroundBashHold.taskShellSearch(
            root: agentPID,
            caller: getpid(),
            suffix: suffix,
            children: ProcessResolver.childMap(),
            openPaths: ProcessResolver.stdioPaths(of:),
        )
        let outputExists = search.pid == nil && BackgroundBashHold.taskOutputExists(
            sessionID: task.sessionID,
            taskID: task.taskID,
            tempRoot: BackgroundBashHold.taskTempRoot(environment: ProcessInfo.processInfo.environment),
            uid: getuid(),
            listDirectories: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
        )

        switch BackgroundBashHold.binding(search: search, outputExists: outputExists) {
        case let .bind(pid):
            cliLog.notice("bind \(task.key, privacy: .public) to shell pid=\(pid, privacy: .public)")
            sendBackground(CLIRequest(op: .acquire, key: task.key, tool: tool, reason: nil, pid: pid, processName: tool, ttlSeconds: task.ttl))
        case .release:
            cliLog.notice("bind \(task.key, privacy: .public) — task already finished, releasing")
            sendBackground(CLIRequest(op: .release, key: task.key, tool: tool, reason: nil, pid: nil, processName: nil, ttlSeconds: nil))
        case .none:
            cliLog.notice("bind \(task.key, privacy: .public) — no shell or output file found; leaving the hold to its TTL")
        }
        exit(0)
    }

    /// Sends a background-hold request, failing soft like every hook path: a warning on stderr, exit 0.
    private static func sendBackground(_ req: CLIRequest) {
        do {
            let resp = try DaemonSocketClient.send(req)
            if !resp.ok {
                FileHandle.standardError.write(Data("adrafinil: \(req.op) refused: \(resp.error ?? "?")\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("adrafinil: background hold update failed (\(error.localizedDescription)) — ignored\n".utf8))
        }
    }

    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let tool = parser.option("--tool") ?? ManualHold.unknownTool
        let reason = parser.option("--reason")
        let ttlRaw = parser.option("--ttl")
        let ttl = ttlRaw.flatMap { Double($0) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if ttlRaw != nil, ttl == nil {
            FileHandle.standardError.write(Data("adrafinil: ignoring invalid --ttl '\(ttlRaw!)'\n".utf8))
        }
        if parser.flag("--bind-background") {
            bindBackground(tool: tool, requestedTTL: ttl)
        }
        let pidRaw = parser.option("--pid")
        let hookPID = pidRaw.flatMap { pid_t($0) }.flatMap { $0 > 0 ? $0 : nil }
        if pidRaw != nil, hookPID == nil {
            FileHandle.standardError.write(Data("adrafinil: ignoring invalid --pid '\(pidRaw!)'\n".utf8))
        }

        let fullKey: String
        let watchedPID: pid_t?
        // The TTL sent to the daemon. Overridden by the background-shell branch to apply its default
        // when `--ttl` was omitted; every other path passes the parsed `--ttl` (nil when absent).
        var effectiveTTL = ttl

        if parser.flag("--if-background") {
            // Opt-in background-shell hook (`PreToolUse`/Bash|Monitor). Places the `bg-` hold that the
            // `PostToolUse` bind then moves onto the shell. A foreground call places NO hold and exits 0
            // silently — it is the common case, so it must never warn.
            let payload = CLIStdin.payload() ?? Data()
            guard let plan = BackgroundBashHold.plan(
                payload: payload,
                tool: tool,
                requestedTTL: ttl,
                uniqueID: BackgroundBashHold.freshID(),
            ) else {
                exit(0)
            }
            fullKey = plan.key
            effectiveTTL = plan.ttl
            let agentPID = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
            watchedPID = agentPID == -1 ? nil : agentPID
            cliLog.notice("acquire \(fullKey, privacy: .public) (background-shell) ttl=\(Int(plan.ttl), privacy: .public)s — resolved owning agent pid=\(agentPID, privacy: .public)\(watchedPID == nil ? " (no agent process matched; daemon will not process-watch)" : "", privacy: .public)")
        } else if parser.flag("--subagent") {
            // Sub-agent lifecycle hook (`SubagentStart`). Key on the sub-agent's own `agent_id` from
            // stdin — NOT `session_id`, which on these payloads is the *parent's* and would collide
            // with the parent turn's hold. This distinct `<tool>:<agent_id>` hold survives the parent
            // `Stop` (the fix for a backgrounded sub-agent sleeping the Mac mid-work) and is released
            // only by the matching `SubagentStop`. There is no positional/env-var fallback — no agent
            // exposes the sub-agent id that way — so a missing `agent_id` fails soft rather than
            // falling back to the parent session.
            guard let agentID = CLIStdin.agentID() else {
                hookFailure("acquire --subagent: no agent_id on stdin — ignored")
            }
            fullKey = ManualHold.sessionKey(tool: tool, sessionID: agentID)
            // Sub-agents run in-process under the parent agent, so the parent-walk resolves the same
            // owning PID — the daemon's CPU-idle/dead-process nets then cover a missed `SubagentStop`.
            let agentPID = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
            watchedPID = agentPID == -1 ? nil : agentPID
            cliLog.notice("acquire \(fullKey, privacy: .public) (subagent) — resolved owning agent pid=\(agentPID, privacy: .public)\(watchedPID == nil ? " (no agent process matched; daemon will not process-watch)" : "", privacy: .public)")
        } else if let kind = AgentKind(rawValue: tool), let pidRel = kind.gatewayPIDFileRelativePath {
            // Gateway/daemon-style agent (e.g. Hermes): one shared long-lived process multiplexes
            // every session, so its per-session start/end hooks don't bracket process lifetime and
            // the session id is irrelevant. Coalesce all sessions onto a single fixed `<tool>:gateway`
            // hold and watch the gateway process read from its pid-file — the parent-walk can't find
            // it (the executable is a generic interpreter). With the gateway PID attached, the daemon's
            // CPU-idle and dead-process nets release the hold when the whole gateway goes quiet or dies,
            // which is what makes a missed/asymmetric end hook safe.
            fullKey = "\(tool):gateway"
            // Check the default pid-file and any per-profile ones (the desktop app and multi-profile
            // setups run the gateway under profiles/<name>/), mirroring Hermes' own gateway discovery.
            let gwPID = ProcessResolver.gatewayPID(homeRoot: NSHomeDirectory(), pidFileRelativePath: pidRel)
            watchedPID = gwPID > 0 ? gwPID : nil
            cliLog.notice("acquire \(tool, privacy: .public) gateway-scoped key=\(fullKey, privacy: .public) — gateway pid=\(gwPID, privacy: .public)\(watchedPID == nil ? " (no live gateway; daemon will not process-watch)" : "", privacy: .public)")
        } else {
            // Prefer the session id from the hook's stdin JSON over the positional arg (which is a
            // shell env-var expansion in the hook command, fragile across agents). Falls back to the
            // positional when stdin has none (manual invocation, or an agent that doesn't pipe JSON).
            // An empty positional is a real failure mode — a hook command whose shell env-var
            // expansion came up empty — and must read as "no key", not as the key "".
            let positional = parser.positional(0)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = CLIStdin.sessionID() ?? (positional?.isEmpty == false ? positional : nil) else {
                hookFailure("acquire: no session key (stdin payload or positional) — ignored")
            }
            fullKey = ManualHold.sessionKey(tool: tool, sessionID: key)
            let agentPID = resolveOwningPID(hookPID: hookPID, tool: tool)
            watchedPID = agentPID == -1 ? nil : agentPID
            cliLog.notice("acquire \(fullKey, privacy: .public) — resolved owning agent pid=\(agentPID, privacy: .public)\(watchedPID == nil ? " (no agent process matched; daemon will not process-watch)" : "", privacy: .public)")
        }

        let wantsDisplay = parser.flag("--display")
        // A Claude Code profile run with `CLAUDE_CONFIG_DIR` writes its session status files under
        // that dir; the hook inherits the variable, so report it and the daemon watches it too. An
        // env read only — the daemon validates and caps it.
        let envConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let claudeConfigDir = tool == AgentKind.claudeCode.rawValue && envConfigDir?.isEmpty == false ? envConfigDir : nil
        let req = CLIRequest(
            op: .acquire,
            key: fullKey,
            tool: tool,
            reason: reason,
            pid: watchedPID,
            processName: tool,
            ttlSeconds: effectiveTTL,
            display: wantsDisplay ? true : nil,
            claudeConfigDir: claudeConfigDir,
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            if !resp.ok {
                FileHandle.standardError.write(Data("adrafinil: acquire refused: \(resp.error ?? "?")\n".utf8))
            }
            // Version-skew check: an old daemon ignores the unknown `display` field and omits the
            // echo — the display is NOT protected, and silence would hide that. Warn (fail-soft:
            // this still runs inside hooks).
            if resp.ok, wantsDisplay, resp.displayApplied == nil {
                FileHandle.standardError.write(Data("adrafinil: the running daemon predates --display — the display is NOT being kept awake. Update Adrafinil and retry.\n".utf8))
            }
            exit(0)
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            FileHandle.standardError.write(Data("adrafinil: daemon not running (acquire ignored)\n".utf8))
            exit(0)
        } catch {
            // Any transport failure — timeout, short read, malformed response — must not fail
            // the agent's hook either.
            FileHandle.standardError.write(Data("adrafinil: acquire failed (\(error.localizedDescription)) — ignored\n".utf8))
            exit(0)
        }
    }
}
