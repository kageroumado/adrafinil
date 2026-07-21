import Foundation

/// Everything an integration needs to know about the local environment: where the `adrafinil` CLI
/// lives (embedded in the hook commands it writes) and which home directory to root `~`-relative
/// config paths at. Production uses `NSHomeDirectory()`; tests inject a temp dir.
struct HookContext {
    let cliPath: String
    let homeRoot: String

    /// The CLI path, shell-quoted unless it is plain enough to need none. POSIX single quotes
    /// neutralize every shell metacharacter (spaces, `$`, quotes, backticks) — the path lives
    /// inside the `.app` bundle, wherever the user put or renamed it.
    var quotedCLI: String {
        if cliPath.range(of: "^[A-Za-z0-9_/.-]+$", options: .regularExpression) != nil {
            return cliPath
        }
        return "'" + cliPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds an `acquire`/`release` hook command. When `sessionVar` is nil the positional session
    /// key is omitted and the CLI sources the session id from the hook's stdin (`session_id`).
    ///
    /// `subagent: true` appends `--subagent`, which makes the CLI key the hold on the sub-agent's
    /// `agent_id` from stdin instead — for the `SubagentStart`/`SubagentStop` hooks, whose hold must
    /// outlive the parent turn's `Stop`. Sub-agent hooks always source their id from stdin, so they
    /// pass no `sessionVar`.
    ///
    /// `ttlSeconds` appends `--ttl <n>`, expiring the hold as a backstop — for agents whose release
    /// signal alone can't be trusted to fire (see `CursorIntegration`).
    func hookCommand(_ op: String, tool: String, sessionVar: String? = nil, subagent: Bool = false, ttlSeconds: Int? = nil) -> String {
        var command = quotedCLI + " " + op
        if let sessionVar { command += " " + sessionVar }
        command += " --tool " + tool
        if subagent { command += " --subagent" }
        if let ttlSeconds { command += " --ttl " + String(ttlSeconds) }
        return command
    }

    /// Builds the background-shell acquire command for a `PreToolUse`(Bash) hook:
    /// `acquire --tool <tool> --if-background --ttl <n>`. It fires when the agent launches a
    /// `run_in_background` shell command — the one signal for a background task that outlives the
    /// turn's `Stop` (which fires no completion hook), so the resulting hold is TTL-bounded. The
    /// `--ttl` precedes no positional, so `--if-background` parses as a bare flag (see `ArgParser`).
    func backgroundAcquireCommand(tool: String, ttlSeconds: Int) -> String {
        quotedCLI + " acquire --tool " + tool + " --if-background --ttl " + String(ttlSeconds)
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

    /// The config file this integration writes its hooks into — the file a "reveal in Finder"
    /// affordance should show. Single source of truth: a UI-side copy of these paths would drift
    /// the moment an integration moves its config.
    func primaryConfigPath(_ ctx: HookContext) -> String

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult
    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult
    func installState(_ ctx: HookContext) -> HookInstallState

    /// How to register Adrafinil's `adrafinil mcp` server in this agent's config, or nil if the
    /// agent has no (verified) MCP support. This is a *separate* capability from the hook wiring
    /// above — hooks track when the agent is working; the MCP server lets the agent deliberately
    /// hold sleep past its turn. Only agents whose MCP config format we've verified return a shape.
    func mcpShape(_ ctx: HookContext) -> MCPServerShape?

    /// How to install Adrafinil's opt-in background-shell hook (a `PreToolUse`/Bash `acquire
    /// --if-background`), or nil if the agent exposes no clean `run_in_background` signal. Like MCP,
    /// this is a *separately-toggled* capability, installed independently of the core acquire/release
    /// wiring so flipping it never rewrites the whole hook set (and, for Codex, never re-triggers the
    /// `/hooks` trust approval). Only Claude Code qualifies today (see `BackgroundBashHold`).
    func backgroundBashShape(_ ctx: HookContext) -> BackgroundBashHookShape?
}

extension AgentIntegration {
    /// Default: no MCP support. Agents override this once their config format is device-verified.
    func mcpShape(_: HookContext) -> MCPServerShape? {
        nil
    }

    /// Default: no background-shell hook. Only agents with a clean `run_in_background` pre-tool
    /// signal (Claude Code) override this.
    func backgroundBashShape(_: HookContext) -> BackgroundBashHookShape? {
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
