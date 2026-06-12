import Foundation

/// Pi: a TS extension at `~/.pi/agent/extensions/adrafinil.ts`. Detected by the `~/.pi` directory.
struct PiIntegration: AgentIntegration {
    let agent = AgentKind.pi

    private func pluginRoot(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.pi/agent/extensions"
    }

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.pi")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.pi/agent/extensions/adrafinil.ts"
    }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try plugin(ctx).install(dryRun: dryRun)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        try plugin(ctx).uninstall(dryRun: dryRun)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        plugin(ctx).installState()
    }

    private func plugin(_ ctx: HookContext) -> FilePlugin {
        FilePlugin(
            pluginRoot: pluginRoot(ctx),
            fileName: "adrafinil.ts",
            content: { Self.extensionTS(cliPath: ctx.cliPath) },
            installSummary: "wrote Pi extension",
        )
    }

    /// Canonical Pi extension. Pi auto-discovers `.ts` extensions and calls `pi.on(<event>, handler)`
    /// from the default export. `session_start` acquires; `session_shutdown` (fired on process exit)
    /// releases. Pi has no session-id env var or stdin payload — the id is the session file path
    /// (`undefined` for ephemeral sessions, so fall back to the pid). Shells out via
    /// `node:child_process`, mirroring the OpenCode plugin.
    ///
    /// Device-verified against pi 0.78.0: this exact extension fired `acquire <session-file> --tool
    /// pi` on `session_start` and `release <same> --tool pi` on `session_shutdown`.
    private static func extensionTS(cliPath: String) -> String {
        """
        import { execFileSync } from "node:child_process"
        
        function run(args) {
          try { execFileSync(\(swiftStringLiteral: cliPath), args) } catch (_) {}
        }
        
        export default function (pi) {
          const id = (ctx) => ctx?.sessionManager?.getSessionFile?.() ?? String(process.pid)
          pi.on("session_start", async (_event, ctx) => run(["acquire", id(ctx), "--tool", "pi"]))
          pi.on("session_shutdown", async (_event, ctx) => run(["release", id(ctx), "--tool", "pi"]))
        }
        """
    }
}

private extension DefaultStringInterpolation {
    /// Emits `item` as a double-quoted JS string literal with proper escaping (JSON string
    /// encoding is a subset of JS), so quotes or backslashes in the bundle path can't break the
    /// generated extension.
    mutating func appendInterpolation(swiftStringLiteral item: String) {
        if let data = try? JSONSerialization.data(withJSONObject: item, options: .fragmentsAllowed),
           let literal = String(data: data, encoding: .utf8) {
            appendInterpolation(literal)
        } else {
            appendInterpolation("\"\(item)\"")
        }
    }
}
