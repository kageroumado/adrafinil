import Foundation

/// Writes (or removes) Adrafinil hook entries inside each agent's config file.
///
/// Atomic per-file. Always reads → mutates → writes a copy. Preserves any
/// non-Adrafinil hook entries the user has installed.
public struct HookInstaller {
    public enum SkipReason: Error, LocalizedError {
        case notInstalled
        case unsupportedHere(String)
        /// The agent's config file exists but isn't a parseable JSON object (comments, a syntax
        /// error mid-edit, an array root). Refusing is the safe move: a read-failure treated as
        /// an empty file would make the next write replace the user's entire config.
        case configUnreadable(String)
        /// The config changed on disk between read and write (agents rewrite their own configs
        /// during sessions). Retrying re-reads the fresh content.
        case concurrentModification(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                "The agent isn't installed on this system."
            case let .unsupportedHere(why):
                why
            case let .configUnreadable(path):
                "\(path) exists but isn't valid JSON — fix or remove it, then retry."
            case let .concurrentModification(path):
                "\(path) changed while updating it (the agent may be running) — retry."
            }
        }
    }

    public struct InstallResult {
        public let summary: String
        public let diff: String

        public init(summary: String, diff: String) {
            self.summary = summary
            self.diff = diff
        }
    }

    /// Absolute path to the adrafinil CLI binary. Embedded in the hook commands.
    public let cliPath: String

    /// Filesystem root for `~` expansion. Production uses `NSHomeDirectory()`; tests inject a temp dir.
    public let homeRoot: String

    public init(cliPath: String, homeRoot: String = NSHomeDirectory()) {
        self.cliPath = cliPath
        self.homeRoot = homeRoot
    }

    private var context: HookContext {
        HookContext(cliPath: cliPath, homeRoot: homeRoot)
    }

    public func install(for agent: AgentKind, dryRun: Bool) throws -> InstallResult {
        let integration = AgentIntegrations.integration(for: agent)
        guard integration.isDetected(context) else { throw SkipReason.notInstalled }
        return try integration.install(context, dryRun: dryRun)
    }

    /// Removes Adrafinil hook entries for `agent`.
    ///
    /// When `dryRun` is `true` the method computes what would change and returns an
    /// `InstallResult` describing the diff without writing anything to disk.
    @discardableResult
    public func uninstall(for agent: AgentKind, dryRun: Bool = false) throws -> InstallResult {
        try AgentIntegrations.integration(for: agent).uninstall(context, dryRun: dryRun)
    }

    /// Returns a list of agents currently detected on the system.
    public static func detectedAgents(homeRoot: String = NSHomeDirectory()) -> [AgentKind] {
        let ctx = HookContext(cliPath: "", homeRoot: homeRoot)
        return AgentKind.allCases.filter { AgentIntegrations.integration(for: $0).isDetected(ctx) }
    }

    /// The config file Adrafinil writes `agent`'s hooks into — for "reveal in Finder".
    public func configPath(for agent: AgentKind) -> String {
        AgentIntegrations.integration(for: agent).primaryConfigPath(context)
    }

    /// Returns the hook-installation state for `agent` (used by the Settings → Agents tab).
    ///
    /// - `.notInstalled` — no Adrafinil entry found in the agent's config.
    /// - `.installed` — an Adrafinil entry exists and matches what `install()` would write.
    /// - `.modifiedExternally` — an Adrafinil-tagged entry exists but differs from the canonical form.
    public func installState(for agent: AgentKind) -> HookInstallState {
        AgentIntegrations.integration(for: agent).installState(context)
    }

    // MARK: - MCP server registration

    /// Whether Adrafinil knows how to register its `adrafinil mcp` server with `agent`. Distinct
    /// from hook support — only agents whose MCP config format is device-verified return true.
    public func supportsMCP(for agent: AgentKind) -> Bool {
        AgentIntegrations.integration(for: agent).mcpShape(context) != nil
    }

    /// Registers Adrafinil's MCP server in `agent`'s config so the agent can call `keep_awake`.
    /// Throws `SkipReason.unsupportedHere` if the agent has no verified MCP support.
    @discardableResult
    public func installMCP(for agent: AgentKind, dryRun: Bool = false) throws -> InstallResult {
        guard let shape = AgentIntegrations.integration(for: agent).mcpShape(context) else {
            throw SkipReason.unsupportedHere("MCP not supported for \(agent.rawValue)")
        }
        return try shape.install(dryRun: dryRun)
    }

    /// Removes Adrafinil's MCP server from `agent`'s config. A no-op for agents without MCP support.
    @discardableResult
    public func uninstallMCP(for agent: AgentKind, dryRun: Bool = false) throws -> InstallResult {
        guard let shape = AgentIntegrations.integration(for: agent).mcpShape(context) else {
            return InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        return try shape.uninstall(dryRun: dryRun)
    }

    /// MCP registration state for `agent` (mirrors `installState`). `.notInstalled` when the agent
    /// has no MCP support at all.
    public func mcpState(for agent: AgentKind) -> HookInstallState {
        AgentIntegrations.integration(for: agent).mcpShape(context)?.installState() ?? .notInstalled
    }
}
