import AdrafinilShared
import Foundation
import OSLog

enum ReleaseCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let tool = parser.option("--tool") ?? "unknown"

        let fullKey: String
        if parser.flag("--subagent") {
            // Sub-agent lifecycle hook (`SubagentStop`). Release the sub-agent's own
            // `<tool>:<agent_id>` hold — keyed on stdin `agent_id`, the same id its `SubagentStart`
            // acquired — never the parent's `session_id`. No fallback: a missing `agent_id` fails soft
            // (the daemon's idle/dead-process nets recover the hold) rather than releasing the wrong key.
            guard let agentID = CLIStdin.agentID() else {
                AcquireCommand.hookFailure("release --subagent: no agent_id on stdin — ignored")
            }
            fullKey = ManualHold.sessionKey(tool: tool, sessionID: agentID)
        } else if let kind = AgentKind(rawValue: tool), kind.isGatewayScoped {
            // Gateway-scoped agent: the hold is coalesced onto the fixed `<tool>:gateway` key
            // (see AcquireCommand), so release targets it directly regardless of session id. This is
            // the fast path back to sleep; the daemon's CPU-idle net is what covers a missed end hook.
            fullKey = "\(tool):gateway"
        } else {
            // Prefer the hook's stdin `session_id` over the positional env-var expansion (see acquire).
            let positional = parser.positional(0)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = CLIStdin.sessionID() ?? (positional?.isEmpty == false ? positional : nil) else {
                AcquireCommand.hookFailure("release: no session key (stdin payload or positional) — ignored")
            }
            // An agent-hold id (`hold:…`) is already the full registry key — release it verbatim. Hook
            // sessions, by contrast, are keyed `<tool>:<session>`. `sessionKey` encodes both rules,
            // and is the same derivation acquire uses, so a session's Stop release targets exactly the
            // key its UserPromptSubmit acquire placed.
            fullKey = ManualHold.sessionKey(tool: tool, sessionID: key)
        }
        Logger(subsystem: AdrafinilConstants.appBundleID, category: "CLI")
            .notice("release \(fullKey, privacy: .public)")

        let req = CLIRequest(
            op: .release,
            key: fullKey,
            tool: tool,
            reason: nil,
            pid: nil,
            processName: nil,
            ttlSeconds: nil,
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            // Releasing an unknown key is a warning, not an error.
            if let warning = resp.warning {
                FileHandle.standardError.write(Data("adrafinil: \(warning)\n".utf8))
            }
            exit(0)
        } catch {
            // Never fail the agent's hook, whatever the transport failure. A missed release is
            // recovered by the daemon's idle sweep and process-exit watcher.
            FileHandle.standardError.write(Data("adrafinil: release failed (\(error.localizedDescription)) — ignored\n".utf8))
            exit(0)
        }
    }
}
