import AdrafinilShared
import Foundation
import OSLog

/// `adrafinil hold` — places an explicit, reasoned, time-boxed sleep block that outlives the
/// agent's turn/session and the agent process itself. Prints the minted hold id on stdout so a
/// script can capture it (`HOLD=$(adrafinil hold --reason "deploy" --for 30m)`); a human summary
/// goes to stderr. Release it with `adrafinil release <id>`, or let it expire.
enum HoldCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let reason = parser.option("--reason")
        let tool = parser.option("--tool")

        // --for accepts a human duration ("30m", "2h", "1h30m"); --ttl stays raw seconds for parity
        // with `acquire`. The daemon clamps to the configured cap regardless.
        var ttl: TimeInterval?
        if let forStr = parser.option("--for") {
            guard let secs = DurationParser.seconds(from: forStr) else {
                FileHandle.standardError.write(Data("hold: could not understand duration '\(forStr)' (try 30m, 2h, 1h30m)\n".utf8))
                exit(2)
            }
            ttl = secs
        } else if let ttlStr = parser.option("--ttl") {
            ttl = Double(ttlStr)
        }

        var pid: pid_t?
        if let pidStr = parser.option("--pid") {
            guard let p = Int32(pidStr), p > 0 else {
                FileHandle.standardError.write(Data("hold: --pid must be a positive process id\n".utf8))
                exit(2)
            }
            pid = p
        }

        Logger(subsystem: AdrafinilConstants.appBundleID, category: "CLI")
            .notice("hold reason='\(reason ?? "", privacy: .public)' ttl=\(ttl.map { String(Int($0)) } ?? "default", privacy: .public) pid=\(pid ?? -1, privacy: .public)")

        let req = CLIRequest(
            op: .hold,
            key: nil,
            tool: tool,
            reason: reason,
            pid: pid,
            processName: tool,
            ttlSeconds: ttl,
        )

        do {
            let resp = try DaemonSocketClient.send(req)
            guard resp.ok, let key = resp.holdKey else {
                FileHandle.standardError.write(Data("hold failed: \(resp.error ?? "unknown error")\n".utf8))
                exit(1)
            }
            // Machine-readable id on stdout; human summary on stderr.
            print(key)
            FileHandle.standardError.write(Data(summary(key: key, ttl: ttl, pid: pid).utf8))
            exit(0)
        } catch {
            // A hold must report failure — unlike a hook acquire, the agent needs to know it did
            // not take so it doesn't assume the Mac will stay awake.
            FileHandle.standardError.write(Data("hold failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func summary(key: String, ttl: TimeInterval?, pid: pid_t?) -> String {
        var parts = ["Keeping your Mac awake"]
        if let pid { parts.append("until process \(pid) exits") }
        if let ttl {
            parts.append("for up to \(humanDuration(ttl))")
        } else {
            parts.append("for up to 1h")
        }
        parts.append("· release with: adrafinil release \(key)")
        return parts.joined(separator: " ") + "\n"
    }

    private static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m\(s)s" : "\(m)m" }
        return "\(s)s"
    }
}
