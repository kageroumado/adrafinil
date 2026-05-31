import Foundation

/// Everything an integration needs to know about the local environment: where the `adrafinil` CLI
/// lives (embedded in the hook commands it writes) and which home directory to root `~`-relative
/// config paths at. Production uses `NSHomeDirectory()`; tests inject a temp dir.
struct HookContext {
    let cliPath: String
    let homeRoot: String

    /// The CLI path, shell-quoted if it contains spaces (it lives inside the `.app` bundle).
    var quotedCLI: String { cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath }

    /// Builds an `acquire`/`release` hook command. When `sessionVar` is nil the positional session
    /// key is omitted and the CLI sources the session id from the hook's stdin (`session_id`).
    func hookCommand(_ op: String, tool: String, sessionVar: String? = nil) -> String {
        if let sessionVar {
            return "\(quotedCLI) \(op) \(sessionVar) --tool \(tool)"
        }
        return "\(quotedCLI) \(op) --tool \(tool)"
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
}

/// The registry mapping every `AgentKind` to its integration. This single exhaustive switch is the
/// one place to register a new agent (the compiler enforces completeness).
enum AgentIntegrations {
    static func integration(for agent: AgentKind) -> AgentIntegration {
        switch agent {
        case .claudeCode: ClaudeCodeIntegration()
        case .codex:      CodexIntegration()
        case .cursor:     CursorIntegration()
        case .geminiCLI:  GeminiCLIIntegration()
        case .crush:      CrushIntegration()
        case .aider:      AiderIntegration()
        case .cline:      ClineIntegration()
        case .hermes:     HermesIntegration()
        case .openCode:   OpenCodeIntegration()
        case .pi:         PiIntegration()
        }
    }
}
