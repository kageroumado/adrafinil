import Foundation
import AdrafinilShared

enum AcquireCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        guard let key = parser.positional(0) else {
            FileHandle.standardError.write(Data("acquire: requires <session-key>\n".utf8))
            exit(2)
        }
        let tool = parser.option("--tool") ?? "unknown"
        let reason = parser.option("--reason")
        let ttl = parser.option("--ttl").flatMap { Double($0) }

        // Walk up the process tree to find the real agent PID.
        // getppid() is the shell (/bin/sh) that runs the hook command — it exits as soon as
        // adrafinil returns, which would cause the daemon to force-release the assertion while
        // the agent is still working. ProcessResolver walks to the first ancestor whose binary
        // name matches a known agent. If no agent is found, we pass nil so the daemon skips
        // process-watching entirely (safer than watching the wrong PID).
        let agentPID = ProcessResolver.owningAgentPID(binaryNames: AgentKind.allBinaryNames)
        let watchedPID: pid_t? = agentPID == -1 ? nil : agentPID

        let req = CLIRequest(
            op: .acquire,
            key: "\(tool):\(key)",
            tool: tool,
            reason: reason,
            pid: watchedPID,
            processName: tool,
            ttlSeconds: ttl
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            if !resp.ok {
                FileHandle.standardError.write(Data("acquire failed: \(resp.error ?? "?")\n".utf8))
            }
            exit(resp.ok ? 0 : 1)
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            // Don't fail the agent's hook if the daemon isn't running.
            FileHandle.standardError.write(Data("adrafinil: daemon not running (acquire ignored)\n".utf8))
            exit(0)
        }
    }
}
