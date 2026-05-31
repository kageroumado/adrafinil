import Foundation

/// Single-file plugin integration for agents that auto-discover plugins/extensions from a directory
/// (OpenCode, Pi). Adrafinil owns exactly one file in that directory; install writes it, uninstall
/// removes only that file (never the shared directory, which may hold the user's other plugins), and
/// the install state compares the on-disk content to the canonical content we'd generate so the two
/// never drift.
struct FilePlugin {
    let pluginRoot: String
    let fileName: String
    /// Generates the canonical plugin file content. Also used to detect external modification.
    let content: () -> String
    let installSummary: String

    private var filePath: String { "\(pluginRoot)/\(fileName)" }

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        if !dryRun {
            try FileManager.default.createDirectory(atPath: pluginRoot, withIntermediateDirectories: true)
            try content().write(toFile: filePath, atomically: true, encoding: .utf8)
        }
        return HookInstaller.InstallResult(summary: installSummary, diff: "+ \(filePath)")
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        if !dryRun { try FileManager.default.removeItem(atPath: filePath) }
        return HookInstaller.InstallResult(summary: "removed plugin file", diff: "- \(filePath)")
    }

    func installState() -> HookInstallState {
        guard FileManager.default.fileExists(atPath: filePath),
              let actual = try? String(contentsOfFile: filePath, encoding: .utf8),
              actual.contains("adrafinil") else { return .notInstalled }
        return actual.trimmingCharacters(in: .whitespacesAndNewlines) ==
               content().trimmingCharacters(in: .whitespacesAndNewlines)
               ? .installed : .modifiedExternally
    }
}
