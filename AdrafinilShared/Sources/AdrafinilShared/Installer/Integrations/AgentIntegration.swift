import Foundation

/// Everything an integration needs to know about the local environment: where the `adrafinil` CLI
/// lives (embedded in the hook commands it writes) and which home directory to root `~`-relative
/// config paths at. Production uses `NSHomeDirectory()`; tests inject a temp dir.
struct HookContext {
    let cliPath: String
    let homeRoot: String

    /// The CLI path, shell-quoted if it contains spaces (it lives inside the `.app` bundle).
    var quotedCLI: String {
        cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath
    }

    /// Builds an `acquire`/`release` hook command. When `sessionVar` is nil the positional session
    /// key is omitted and the CLI sources the session id from the hook's stdin (`session_id`).
    func hookCommand(_ op: String, tool: String, sessionVar: String? = nil) -> String {
        if let sessionVar {
            return "\(quotedCLI) \(op) \(sessionVar) --tool \(tool)"
        }
        return "\(quotedCLI) \(op) --tool \(tool)"
    }

    /// The name Adrafinil registers its MCP server under in each agent's config. Constant across
    /// agents, and its own idempotency handle (a named key, unlike the array-based hook entries).
    static let mcpServerName = "adrafinil"

    /// The canonical MCP server entry registered into an agent's config: spawns `adrafinil mcp
    /// --tool <agent>` over stdio, so holds the agent places carry its name. Unlike `hookCommand`,
    /// the path is *unquoted* — MCP `command`/`args` are exec'd directly, not via a shell, so a
    /// bundle path with spaces is fine as a single argv element.
    func mcpEntry(tool: String) -> [String: Any] {
        ["type": "stdio", "command": cliPath, "args": ["mcp", "--tool", tool]]
    }
}

/// Per-agent integration: how to detect the tool, and how to install / uninstall / inspect the hook
/// wiring that makes it call `adrafinil acquire`/`release`. One conforming type per agent, each in
/// its own file under `Integrations/`, so adding a tool is a single-file change plus one line in
/// `AgentIntegrations.integration(for:)`.
///
/// The shared mechanics live in `Integrations/Support/`: `NestedJSONHookShape` and
/// `FlatJSONHookShape` (JSON config files), `ShellWrapper` (rc-alias agents), and `FilePlugin`
/// (single-file plugins). Each integration is mostly a description of paths and commands that
/// delegates to one of those.
protocol AgentIntegration {
    var agent: AgentKind { get }

    /// Whether the agent appears installed on this system. Heuristic — checks for the config dir
    /// or the binary on PATH.
    func isDetected(_ ctx: HookContext) -> Bool

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult
    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult
    func installState(_ ctx: HookContext) -> HookInstallState

    /// How to register Adrafinil's `adrafinil mcp` server in this agent's config, or nil if the
    /// agent has no (verified) MCP support. This is a *separate* capability from the hook wiring
    /// above — hooks track when the agent is working; the MCP server lets the agent deliberately
    /// hold sleep past its turn. Only agents whose MCP config format we've verified return a shape.
    func mcpShape(_ ctx: HookContext) -> MCPServerShape?
}

extension AgentIntegration {
    /// Default: no MCP support. Agents override this once their config format is device-verified.
    func mcpShape(_: HookContext) -> MCPServerShape? {
        nil
    }
}

/// The registry mapping every `AgentKind` to its integration. This single exhaustive switch is the
/// one place to register a new agent (the compiler enforces completeness).
enum AgentIntegrations {
    static func integration(for agent: AgentKind) -> AgentIntegration {
        switch agent {
        case .claudeCode: ClaudeCodeIntegration()
        case .codex: CodexIntegration()
        case .cursor: CursorIntegration()
        case .geminiCLI: GeminiCLIIntegration()
        case .aider: AiderIntegration()
        case .cline: ClineIntegration()
        case .hermes: HermesIntegration()
        case .openCode: OpenCodeIntegration()
        case .pi: PiIntegration()
        }
    }
}
