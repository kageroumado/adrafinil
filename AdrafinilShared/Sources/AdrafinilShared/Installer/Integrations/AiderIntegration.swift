import Foundation

/// Aider: no hook system, so Adrafinil installs a `ShellWrapper` — a wrapper script plus a shell
/// alias in `~/.zshrc`/`~/.bashrc` that brackets `aider` with `acquire`/`release`. Detected by the
/// `aider` binary on PATH.
struct AiderIntegration: AgentIntegration {
    let agent = AgentKind.aider

    func isDetected(_: HookContext) -> Bool {
        binaryOnPath("aider")
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
