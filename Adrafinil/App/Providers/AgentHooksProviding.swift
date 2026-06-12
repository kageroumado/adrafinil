import AdrafinilShared
import AppKit
import Foundation

/// Hook install/inspect operations for the Agents settings tab and the installer's agent list.
/// Live wraps `HookInstaller` + `CLISymlinker`; previews inject canned install states.
@MainActor
protocol AgentHooksProviding {
    func detectedAgents() -> [AgentKind]
    func installState(for kind: AgentKind) -> HookInstallState
    func install(for kind: AgentKind) throws
    func uninstall(for kind: AgentKind) throws
    /// Reveals the agent's hook config (or its parent dir) in Finder.
    func revealConfig(for kind: AgentKind)

    // MCP server registration — a separate capability from hooks. Hooks track when an agent works;
    // the MCP server lets it deliberately hold sleep past its turn. Only verified agents support it.
    func mcpSupported(for kind: AgentKind) -> Bool
    func mcpState(for kind: AgentKind) -> HookInstallState
    func installMCP(for kind: AgentKind) throws
    func uninstallMCP(for kind: AgentKind) throws
}

@MainActor
struct LiveAgentHooksProvider: AgentHooksProviding {
    private var installer: HookInstaller {
        HookInstaller(cliPath: CLISymlinker.hookCLIPath)
    }

    func detectedAgents() -> [AgentKind] {
        HookInstaller.detectedAgents()
    }
    func installState(for kind: AgentKind) -> HookInstallState {
        installer.installState(for: kind)
    }
    func install(for kind: AgentKind) throws {
        _ = try installer.install(for: kind, dryRun: false)
    }
    func uninstall(for kind: AgentKind) throws {
        try installer.uninstall(for: kind)
    }

    func mcpSupported(for kind: AgentKind) -> Bool {
        installer.supportsMCP(for: kind)
    }
    func mcpState(for kind: AgentKind) -> HookInstallState {
        installer.mcpState(for: kind)
    }
    func installMCP(for kind: AgentKind) throws {
        try installer.installMCP(for: kind)
    }
    func uninstallMCP(for kind: AgentKind) throws {
        try installer.uninstallMCP(for: kind)
    }

    func revealConfig(for kind: AgentKind) {
        // The path comes from the integration itself, so this can't drift from where the
        // installer actually writes.
        let fm = FileManager.default
        let path = installer.configPath(for: kind)
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        if fm.fileExists(atPath: dir) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        }
    }
}

#if DEBUG
    /// A canned `AgentHooksProviding` for previews/gallery. Toggling install just flips the in-memory
    /// state so the row's chip updates live.
    @MainActor
    final class PreviewAgentHooksProvider: AgentHooksProviding {
        private var states: [(kind: AgentKind, state: HookInstallState)]
        /// MCP registration state per agent, mirroring the live installer's separate capability.
        private var mcpStates: [AgentKind: HookInstallState] = [
            .claudeCode: .installed,
            .geminiCLI: .notInstalled,
        ]
        /// Agents the preview reports as MCP-capable (matches the device-verified set in the shared
        /// package — Cursor/Gemini are gated off until verified, so only Claude Code qualifies).
        private let mcpCapable: Set<AgentKind> = [.claudeCode]

        init(_ states: [(AgentKind, HookInstallState)] = PreviewAgentHooksProvider.defaultStates) {
            self.states = states.map { (kind: $0.0, state: $0.1) }
        }

        static let defaultStates: [(AgentKind, HookInstallState)] = [
            (.claudeCode, .installed),
            (.codex, .installed),
            (.cursor, .notInstalled),
            (.geminiCLI, .modifiedExternally),
            (.aider, .notInstalled),
        ]

        func detectedAgents() -> [AgentKind] {
            states.map(\.kind)
        }
        func installState(for kind: AgentKind) -> HookInstallState {
            states.first { $0.kind == kind }?.state ?? .notInstalled
        }
        func install(for kind: AgentKind) throws {
            setState(.installed, for: kind)
        }
        func uninstall(for kind: AgentKind) throws {
            setState(.notInstalled, for: kind)
        }
        func revealConfig(for _: AgentKind) {}

        func mcpSupported(for kind: AgentKind) -> Bool {
            mcpCapable.contains(kind)
        }
        func mcpState(for kind: AgentKind) -> HookInstallState {
            mcpStates[kind] ?? .notInstalled
        }
        func installMCP(for kind: AgentKind) throws {
            mcpStates[kind] = .installed
        }
        func uninstallMCP(for kind: AgentKind) throws {
            mcpStates[kind] = .notInstalled
        }

        private func setState(_ state: HookInstallState, for kind: AgentKind) {
            if let i = states.firstIndex(where: { $0.kind == kind }) { states[i].state = state }
        }
    }
#endif
