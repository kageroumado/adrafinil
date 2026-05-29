import Foundation
import AdrafinilShared

enum StatusCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let jsonMode = parser.flag("--json")

        let req = CLIRequest(op: .status, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)

        let resp: CLIResponse
        do {
            resp = try DaemonSocketClient.send(req)
        } catch DaemonSocketClient.ClientError.daemonUnreachable {
            if jsonMode {
                print(#"{"daemonRunning":false}"#)
            } else {
                print("Adrafinil daemon is not running.")
            }
            exit(1)
        }

        if jsonMode {
            if let data = resp.statusJSON, let s = String(data: data, encoding: .utf8) {
                print(s)
            } else {
                print(#"{"daemonRunning":true,"statusUnavailable":true}"#)
            }
            return
        }

        guard let data = resp.statusJSON,
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
            print("Daemon responded but status could not be decoded.")
            return
        }

        print("Adrafinil — \(status.isBlocking ? "blocking sleep" : "idle")")
        print("  Assertions: \(status.assertions.count)")
        for a in status.assertions {
            let mins = Int(a.age / 60)
            let secs = Int(a.age) % 60
            print("    • \(a.tool) [\(a.key)] — \(mins)m \(secs)s\(a.reason.map { " — \($0)" } ?? "")")
        }
        print("  Lid: \(status.lidClosed ? "closed" : "open")")
        if let t = status.cpuTemperatureCelsius {
            print("  CPU temp: \(String(format: "%.1f", t))°C")
        }
        print("  Helper: \(status.helperConnected ? "connected" : "disconnected")")
    }
}
