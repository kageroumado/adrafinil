import AdrafinilShared
import Foundation

/// `adrafinil mcp` — a Model Context Protocol server (JSON-RPC 2.0 over stdio) that exposes agent
/// holds as native, agent-callable tools. An agent configured with this server can keep the Mac
/// awake for a background job *itself*, with a reason and a timeout, without knowing the CLI.
///
/// Transport per the MCP spec: each line of stdin is one JSON-RPC message; each response is one
/// line on stdout. All diagnostics go to stderr so they never corrupt the protocol stream. Tool
/// calls are synchronous round-trips to the daemon over the same Unix socket the CLI uses.
enum MCPServer {
    /// MCP revision we implement, and the revisions close enough that echoing them is honest
    /// (newline-delimited JSON-RPC stdio, text tool results).
    private static let defaultProtocolVersion = "2024-11-05"
    private static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26"]
    private static let serverVersion = AdrafinilConstants.marketingVersion

    static func run(args: [String]) {
        let parser = ArgParser(args: args)
        // Registered per-agent (e.g. `adrafinil mcp --tool claude`), so holds carry the agent's
        // name in the popover. Falls back to the generic "manual" label.
        let toolLabel = parser.option("--tool") ?? ManualHold.defaultTool

        logErr("adrafinil mcp server ready (tool=\(toolLabel))")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                // A client awaiting a reply to a request id would otherwise sit on its own
                // timeout; JSON-RPC defines -32700 for exactly this.
                send(id: nil, error: -32_700, message: "Parse error")
                continue
            }
            guard let msg = parsed as? [String: Any] else {
                send(id: nil, error: -32_600, message: "Invalid request: expected a JSON-RPC object")
                continue
            }
            handle(msg, toolLabel: toolLabel)
        }
    }

    // MARK: - Dispatch

    private static func handle(_ msg: [String: Any], toolLabel: String) {
        let id = msg["id"] // absent for notifications
        guard let method = msg["method"] as? String else { return }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            // Echo a requested revision only if it's one this server actually implements; for an
            // unknown revision the spec says to answer with our own latest, never to claim
            // support for semantics (structured tool results, batches) we don't have.
            let requested = params["protocolVersion"] as? String
            let version = supportedProtocolVersions.contains(requested ?? "") ? requested! : defaultProtocolVersion
            send(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "adrafinil", "version": serverVersion],
            ])
        case "notifications/initialized", "notifications/cancelled":
            break // notifications take no response
        case "ping":
            send(id: id, result: [String: Any]())
        case "tools/list":
            send(id: id, result: ["tools": toolDefinitions])
        case "tools/call":
            handleToolCall(id: id, params: params, toolLabel: toolLabel)
        default:
            if id != nil {
                send(id: id, error: -32_601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Tools

    private static var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "keep_awake",
                "description": "Keep this Mac fully awake for a background task that will outlive the current turn — e.g. a build, deploy, migration, or training run you just started. This blocks sleep COMPLETELY, including the closed-lid (clamshell) case with the display off and on battery — unlike `caffeinate`, which only prevents idle sleep and still lets the Mac sleep when the user shuts the lid. So the task keeps running even after the user closes the laptop and walks away. Returns a hold id. The hold ends when you call release_awake, when the named process exits, or when its time runs out. Use this when work continues after you finish responding; you do NOT need it for work done within your turn.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "reason": [
                            "type": "string",
                            "description": "Short human-readable reason, shown to the user (e.g. 'running database migration').",
                        ],
                        "minutes": [
                            "type": "number",
                            "description": "How long to hold, in minutes. Optional; defaults to 60 and is capped by the user's setting. Prefer a realistic estimate over a large value.",
                        ],
                        "pid": [
                            "type": "integer",
                            "description": "Optional process id of the background job. When given, the hold releases automatically the moment that process exits — the most precise option.",
                        ],
                    ],
                    "required": ["reason"],
                ],
            ],
            [
                "name": "release_awake",
                "description": "Release a hold placed by keep_awake, letting the Mac sleep normally again once nothing else is holding it awake. Call this as soon as the background task finishes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "hold_id": [
                            "type": "string",
                            "description": "The hold id returned by keep_awake (looks like 'hold:abc12345').",
                        ],
                    ],
                    "required": ["hold_id"],
                ],
            ],
            [
                "name": "awake_status",
                "description": "Report whether the Mac is currently being kept awake, and by what (active agents and holds, with their reasons and time remaining).",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
            ],
        ]
    }

    private static func handleToolCall(id: Any?, params: [String: Any], toolLabel: String) {
        guard let name = params["name"] as? String else {
            send(id: id, error: -32_602, message: "tools/call requires a tool name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "keep_awake": keepAwake(id: id, arguments: arguments, toolLabel: toolLabel)
        case "release_awake": releaseAwake(id: id, arguments: arguments)
        case "awake_status": awakeStatus(id: id)
        default: sendToolResult(id: id, text: "Unknown tool: \(name)", isError: true)
        }
    }

    private static func keepAwake(id: Any?, arguments: [String: Any], toolLabel: String) {
        guard let reason = (arguments["reason"] as? String), !reason.isEmpty else {
            sendToolResult(id: id, text: "keep_awake requires a 'reason'.", isError: true)
            return
        }
        let ttl: TimeInterval? = (arguments["minutes"] as? NSNumber).map { $0.doubleValue * 60 }
        // `exactly:` — a wrapped out-of-range pid would tie the hold's lifetime to whatever
        // unrelated process the truncated value happens to name.
        let pid: pid_t? = (arguments["pid"] as? NSNumber).flatMap { pid_t(exactly: $0) }

        let req = CLIRequest(
            op: .hold,
            key: nil,
            tool: toolLabel,
            reason: reason,
            pid: (pid ?? 0) > 0 ? pid : nil,
            processName: toolLabel,
            ttlSeconds: ttl,
        )
        do {
            let resp = try DaemonSocketClient.send(req)
            guard resp.ok, let key = resp.holdKey else {
                sendToolResult(id: id, text: resp.error ?? "Could not place the hold.", isError: true)
                return
            }
            var text = "Keeping the Mac awake, including with the lid closed (hold id: \(key))."
            // The daemon clamps the TTL to the user's cap — report what was applied, not what
            // was asked for, so the agent doesn't plan around time it won't get.
            let applied = resp.appliedTTLSeconds ?? ttl ?? ManualHold.defaultTTL
            if let pid, pid > 0 {
                text += " Releases when process \(pid) exits, or in about \(Int((applied / 60).rounded())) min"
            } else {
                text += " Expires in about \(Int((applied / 60).rounded())) min"
            }
            text += " — call release_awake with this id when the task finishes."
            sendToolResult(id: id, text: text)
        } catch {
            sendToolResult(id: id, text: "The Adrafinil daemon isn't reachable, so the hold was not placed.", isError: true)
        }
    }

    private static func releaseAwake(id: Any?, arguments: [String: Any]) {
        guard let holdID = (arguments["hold_id"] as? String), !holdID.isEmpty else {
            sendToolResult(id: id, text: "release_awake requires a 'hold_id'.", isError: true)
            return
        }
        let req = CLIRequest(op: .release, key: holdID, tool: "mcp", reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
        do {
            let resp = try DaemonSocketClient.send(req)
            if let warning = resp.warning {
                sendToolResult(id: id, text: "Nothing to release — \(warning)")
            } else {
                sendToolResult(id: id, text: "Released \(holdID). The Mac can sleep normally once nothing else is holding it awake.")
            }
        } catch {
            sendToolResult(id: id, text: "The Adrafinil daemon isn't reachable.", isError: true)
        }
    }

    private static func awakeStatus(id: Any?) {
        let req = CLIRequest(op: .status, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
        do {
            let resp = try DaemonSocketClient.send(req)
            guard let data = resp.statusJSON,
                  let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                sendToolResult(id: id, text: "Could not read status from the daemon.", isError: true)
                return
            }
            sendToolResult(id: id, text: describe(status))
        } catch {
            sendToolResult(id: id, text: "The Adrafinil daemon isn't reachable.", isError: true)
        }
    }

    private static func describe(_ status: DaemonStatus) -> String {
        if status.paused { return "Adrafinil is paused — the Mac will sleep normally regardless of agents or holds." }
        guard !status.assertions.isEmpty else {
            return "The Mac is sleeping normally — nothing is keeping it awake."
        }
        var lines = ["The Mac is being kept awake by \(status.assertions.count) item(s):"]
        for a in status.assertions {
            let kind = ManualHold.isHoldKey(a.key) ? "hold" : "agent"
            var line = "• [\(kind)] \(a.tool)"
            if let reason = a.reason, !reason.isEmpty { line += " — \(reason)" }
            if let remaining = a.timeRemaining, remaining > 0 { line += " (\(Int((remaining / 60).rounded())) min left)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON-RPC writing

    private static func sendToolResult(id: Any?, text: String, isError: Bool = false) {
        send(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])
    }

    private static func send(id: Any?, result: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id ?? NSNull()
        write(payload)
    }

    private static func send(id: Any?, error code: Int, message: String) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        payload["id"] = id ?? NSNull()
        write(payload)
    }

    private static func write(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A) // newline-delimited transport
        // A client that closed stdout while keeping stdin open must not crash the server with an
        // ObjC exception — the throwing variant surfaces EPIPE as a catchable error instead.
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func logErr(_ message: String) {
        FileHandle.standardError.write(Data("[adrafinil mcp] \(message)\n".utf8))
    }
}
