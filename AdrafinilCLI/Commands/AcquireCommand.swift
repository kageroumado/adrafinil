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

    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let tool = parser.option("--tool") ?? "unknown"
        let reason = parser.option("--reason")
        let ttlRaw = parser.option("--ttl")
        let ttl = ttlRaw.flatMap { Double($0) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if ttlRaw != nil, ttl == nil {
            FileHandle.standardError.write(Data("adrafinil: ignoring invalid --ttl '\(ttlRaw!)'\n".utf8))
        }

        let fullKey: String
        let watchedPID: pid_t?

        if let kind = AgentKind(rawValue: tool), let pidRel = kind.gatewayPIDFileRelativePath {
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
            fullKey = "\(tool):\(key)"
            // Walk up the process tree to find the real agent PID.
            // getppid() is the shell (/bin/sh) that runs the hook command — it exits as soon as
            // adrafinil returns, which would cause the daemon to force-release the assertion while
            // the agent is still working. ProcessResolver walks to the first ancestor whose binary
            // name matches a known agent. If no agent is found, we pass nil so the daemon skips
            // process-watching entirely (safer than watching the wrong PID).
            let agentPID = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
            watchedPID = agentPID == -1 ? nil : agentPID
            cliLog.notice("acquire \(tool, privacy: .public):\(key, privacy: .public) — resolved owning agent pid=\(agentPID, privacy: .public)\(watchedPID == nil ? " (no agent process matched; daemon will not process-watch)" : "", privacy: .public)")
        }

        let req = CLIRequest(
            op: .acquire,
            key: fullKey,
            tool: tool,
            reason: reason,
            pid: watchedPID,
            processName: tool,
            ttlSeconds: ttl,
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            if !resp.ok {
                FileHandle.standardError.write(Data("adrafinil: acquire refused: \(resp.error ?? "?")\n".utf8))
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
