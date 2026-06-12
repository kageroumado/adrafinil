import Foundation

/// Cline: same `ShellWrapper` approach as Aider — a wrapper script + shell alias, since Cline has
/// no terminal hook system. Detected by the `cline` binary on PATH.
///
/// > Limited: this only wraps terminal `cline` invocations and misses in-editor VS Code sessions.
/// > Cline's native `~/Documents/Cline/Rules/Hooks/` would be the proper path for those.
struct ClineIntegration: AgentIntegration {
    let agent = AgentKind.cline

    func isDetected(_: HookContext) -> Bool {
        binaryOnPath("cline")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.zshrc"
    }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try wrapper(ctx).install(dryRun: dryRun)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try wrapper(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        wrapper(ctx).installState()
    }

    private func wrapper(_ ctx: HookContext) -> ShellWrapper {
        ShellWrapper(toolName: agent.rawValue, cliPath: ctx.cliPath, homeRoot: ctx.homeRoot)
    }
}
