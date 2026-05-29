import Foundation
import AdrafinilShared

enum ReleaseCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        guard let key = parser.positional(0) else {
            FileHandle.standardError.write(Data("release: requires <session-key>\n".utf8))
            exit(2)
        }
        let tool = parser.option("--tool") ?? "unknown"

        let req = CLIRequest(
            op: .release,
            key: "\(tool):\(key)",
            tool: tool,
            reason: nil,
            pid: nil,
            processName: nil,
            ttlSeconds: nil
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            // SPEC §5.6/§8: releasing an unknown key is a warning, not an error.
            if let warning = resp.warning {
                FileHandle.standardError.write(Data("adrafinil: \(warning)\n".utf8))
            }
            exit(0)
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            exit(0) // never fail the agent's hook
        }
    }
}
