import Foundation

/// All agentic tools Adrafinil knows about.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode  = "claude-code"
    case codex       = "codex"
    case cursor      = "cursor"
    case geminiCLI   = "gemini-cli"
    case crush       = "crush"
    case aider       = "aider"
    case hermes      = "hermes"
    case openCode    = "opencode"
    case cline       = "cline"
    case pi          = "pi"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .cursor:     "Cursor"
        case .geminiCLI:  "Gemini CLI"
        case .crush:      "Crush"
        case .aider:      "Aider"
        case .hermes:     "Hermes"
        case .openCode:   "OpenCode"
        case .cline:      "Cline"
        case .pi:         "Pi"
        }
    }

    /// Binary name(s) used by process sniffer.
    public var binaryNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex:      ["codex"]
        case .cursor:     ["cursor", "Cursor"]
        case .geminiCLI:  ["gemini"]
        case .crush:      ["crush"]
        case .aider:      ["aider"]
        case .hermes:     ["hermes"]
        case .openCode:   ["opencode"]
        case .cline:      ["cline"]
        // `pi` runs as a Node process (argv0 often "node"), so the sniffer rarely matches it —
        // the TS extension hook is the real integration; this is a weak best-effort fallback.
        case .pi:         ["pi"]
        }
    }

    /// Every known binary name across all agents. Cached: the mapping is static.
    public static let allBinaryNames: Set<String> = Set(allCases.flatMap(\.binaryNames))

    /// Reverse lookup from a binary name to its agent. Cached: the mapping is static.
    public static let byBinaryName: [String: AgentKind] = {
        var map: [String: AgentKind] = [:]
        for kind in allCases {
            for name in kind.binaryNames { map[name] = kind }
        }
        return map
    }()

    /// Identify the agent owning a running process, matching the basename first and then any
    /// path component — so versioned installs (e.g. `…/claude/versions/2.1.156`, basename
    /// `2.1.156`) are still recognized by their `claude` path segment. Returns nil if unknown.
    public static func forRunningProcess(name: String, path: String) -> AgentKind? {
        if let kind = byBinaryName[name] { return kind }
        for component in (path as NSString).pathComponents {
            if let kind = byBinaryName[component] { return kind }
        }
        return nil
    }

    /// For an agent that runs as a single long-lived **shared process** (a gateway/daemon)
    /// multiplexing many logical sessions — rather than one process per session — this is the path,
    /// relative to the user's home, of the pid-file that process writes. `nil` for the normal
    /// one-process-per-session agents.
    ///
    /// Such agents need different hold bookkeeping: (1) their per-session start/end hooks don't
    /// bracket process lifetime, so a hold is keyed to a single fixed gateway scope rather than per
    /// session, and (2) the executable is a generic interpreter (Hermes runs as
    /// `python -m hermes_cli.main gateway run`), so `ProcessResolver.owningAgentPID`'s parent-walk
    /// can't identify it — the watched PID is read from this file instead. With a real PID attached,
    /// the daemon's CPU-idle and dead-process release nets apply to the gateway tree.
    public var gatewayPIDFileRelativePath: String? {
        switch self {
        case .hermes: ".hermes/gateway.pid"
        default:      nil
        }
    }

    /// Whether this agent runs as a shared gateway/daemon process (see `gatewayPIDFileRelativePath`).
    public var isGatewayScoped: Bool { gatewayPIDFileRelativePath != nil }

    /// Integration tier: 1 = full hooks, 2 = partial/wrapper/plugin needed.
    public var tier: Int {
        switch self {
        case .claudeCode, .codex, .cursor, .geminiCLI: 1
        case .crush, .aider, .hermes, .openCode, .cline, .pi: 2
        }
    }
}
