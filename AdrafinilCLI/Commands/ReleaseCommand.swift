import Foundation
import OSLog
import AdrafinilShared

enum ReleaseCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let tool = parser.option("--tool") ?? "unknown"

        let fullKey: String
        if let kind = AgentKind(rawValue: tool), kind.isGatewayScoped {
            // Gateway-scoped agent: the hold is coalesced onto the fixed `<tool>:gateway` key
            // (see AcquireCommand), so release targets it directly regardless of session id. This is
            // the fast path back to sleep; the daemon's CPU-idle net is what covers a missed end hook.
            fullKey = "\(tool):gateway"
        } else {
            // Prefer the hook's stdin `session_id` over the positional env-var expansion (see acquire).
            guard let key = CLIStdin.sessionID() ?? parser.positional(0) else {
                FileHandle.standardError.write(Data("release: requires <session-key>\n".utf8))
                exit(2)
            }
            // An agent-hold id (`hold:…`) is already the full registry key — release it verbatim. Hook
            // sessions, by contrast, are keyed `<tool>:<session>`, so those get the tool prefix.
            fullKey = ManualHold.isHoldKey(key) ? key : "\(tool):\(key)"
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
            ttlSeconds: nil
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            // Releasing an unknown key is a warning, not an error.
            if let warning = resp.warning {
                FileHandle.standardError.write(Data("adrafinil: \(warning)\n".utf8))
            }
            exit(0)
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            exit(0) // never fail the agent's hook
        }
    }
}
