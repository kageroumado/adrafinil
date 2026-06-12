import AdrafinilShared
import Foundation

/// `adrafinil daemon-status` — quick liveness check for the daemon.
///
/// Sends a `.ping` request and prints whether the daemon is reachable. Exits 0 in both
/// cases — the intent is informational, not a hard failure gate for agent hooks.
enum DaemonStatusCommand {
    static func run(args _: [String]) throws {
        let req = CLIRequest(
            op: .ping,
            key: nil,
            tool: nil,
            reason: nil,
            pid: nil,
            processName: nil,
            ttlSeconds: nil,
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            if resp.ok {
                print("daemon: running")
            } else {
                print("daemon: running (reported not-ok: \(resp.error ?? "unknown"))")
            }
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            print("daemon: not running (open the Adrafinil app to start it)")
        } catch {
            print("daemon: unreachable (\(error.localizedDescription))")
        }
    }
}
