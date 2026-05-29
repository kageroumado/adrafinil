import Foundation

/// All agentic tools Adrafinil knows about.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode  = "claude-code"
    case codex       = "codex"
    case cursor      = "cursor"
    case geminiCLI   = "gemini-cli"
    case goose       = "goose"
    case crush       = "crush"
    case aider       = "aider"
    case hermes      = "hermes"
    case openCode    = "opencode"
    case cline       = "cline"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .cursor:     "Cursor"
        case .geminiCLI:  "Gemini CLI"
        case .goose:      "Goose"
        case .crush:      "Crush"
        case .aider:      "Aider"
        case .hermes:     "Hermes"
        case .openCode:   "OpenCode"
        case .cline:      "Cline"
        }
    }

    /// Binary name(s) used by process sniffer.
    public var binaryNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex:      ["codex"]
        case .cursor:     ["cursor", "Cursor"]
        case .geminiCLI:  ["gemini"]
        case .goose:      ["goose", "goose-cli"]
        case .crush:      ["crush"]
        case .aider:      ["aider"]
        case .hermes:     ["hermes"]
        case .openCode:   ["opencode"]
        case .cline:      ["cline"]
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

    /// Integration tier: 1 = full hooks, 2 = partial/wrapper/plugin needed.
    public var tier: Int {
        switch self {
        case .claudeCode, .codex, .cursor, .geminiCLI, .goose: 1
        case .crush, .aider, .hermes, .openCode, .cline: 2
        }
    }
}
