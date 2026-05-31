import Foundation
import OSLog
import AdrafinilShared

enum ReleaseCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        // Prefer the hook's stdin `session_id` over the positional env-var expansion (see acquire).
        guard let key = CLIStdin.sessionID() ?? parser.positional(0) else {
            FileHandle.standardError.write(Data("release: requires <session-key>\n".utf8))
            exit(2)
        }
        let tool = parser.option("--tool") ?? "unknown"

        // An agent-hold id (`hold:…`) is already the full registry key — release it verbatim. Hook
        // sessions, by contrast, are keyed `<tool>:<session>`, so those get the tool prefix.
        let fullKey = ManualHold.isHoldKey(key) ? key : "\(tool):\(key)"
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
