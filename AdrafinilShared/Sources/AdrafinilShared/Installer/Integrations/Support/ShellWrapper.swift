import Foundation

/// Shell-alias integration for agents with no hook system (Aider, Cline). Writes a standalone
/// wrapper script (`~/.local/bin/<agent>-adrafinil`) that brackets the real tool with
/// `acquire`/`release`, and an alias in both `~/.zshrc` and `~/.bashrc` so the wrapper runs
/// regardless of which shell the user's terminal launches.
///
/// > Cline note: this misses in-editor VS Code sessions — only terminal `cline` invocations are
/// > wrapped. Cline's native `~/Documents/Cline/Rules/Hooks/` would be the proper path for those.
struct ShellWrapper {
    let toolName: String // AgentKind.rawValue, e.g. "aider"
    let cliPath: String
    let homeRoot: String

    /// Path for the standalone wrapper script, e.g. `~/.local/bin/aider-adrafinil`.
    private var wrapperScriptPath: String {
        "\(homeRoot)/.local/bin/\(toolName)-adrafinil"
    }

    /// Shell rc files that receive the alias.
    private var shellRCPaths: [String] {
        ["\(homeRoot)/.zshrc", "\(homeRoot)/.bashrc"]
    }

    private var quotedCLI: String {
        cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath
    }
    private var marker: String {
        "# adrafinil-\(toolName)"
    }
    private var endMarker: String {
        "# end-adrafinil-\(toolName)"
    }

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let scriptPath = wrapperScriptPath
        // The wrapper script: acquire → run the real tool → release.
        let script = """
        #!/usr/bin/env bash
        \(quotedCLI) acquire $$ --tool \(toolName)
        \(toolName) "$@"
        status=$?
        \(quotedCLI) release $$ --tool \(toolName)
        exit $status
        """

        let alias = "alias \(toolName)='\(scriptPath)'"
        let block = "\(marker)\n\(alias)\n\(endMarker)"

        var diff = ""
        var changed = false

        for rcPath in shellRCPaths {
            var current = (try? String(contentsOfFile: rcPath, encoding: .utf8)) ?? ""
            if current.contains(marker) { continue }
            current += "\n" + block + "\n"
            if !dryRun { try current.write(toFile: rcPath, atomically: true, encoding: .utf8) }
            diff += "+ \(rcPath): \(alias)\n"
            changed = true
        }

        if !FileManager.default.fileExists(atPath: scriptPath) {
            diff += "+ \(scriptPath) (wrapper script)\n"
            if !dryRun {
                let dir = (scriptPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                chmod(scriptPath, 0o755)
            }
            changed = true
        }

        if !changed { return HookInstaller.InstallResult(summary: "already installed", diff: "(unchanged)") }
        return HookInstaller.InstallResult(summary: "installed \(toolName)-adrafinil wrapper + alias", diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        var diff = ""
        for rcPath in shellRCPaths {
            guard let current = try? String(contentsOfFile: rcPath, encoding: .utf8) else { continue }
            var out: [String] = []
            var inBlock = false
            for line in current.components(separatedBy: "\n") {
                if line.hasPrefix(marker) { inBlock = true; continue }
                if line.hasPrefix(endMarker) { inBlock = false; continue }
                if inBlock { continue }
                // Legacy single-line marker support (no end marker).
                if line.hasPrefix("# adrafinil-"), line.contains(toolName) { continue }
                out.append(line)
            }
            let updated = out.joined(separator: "\n")
            if updated != current {
                diff += "- \(rcPath): removed alias block\n"
                if !dryRun { try updated.write(toFile: rcPath, atomically: true, encoding: .utf8) }
            }
        }

        if FileManager.default.fileExists(atPath: wrapperScriptPath) {
            diff += "- \(wrapperScriptPath)\n"
            if !dryRun { try? FileManager.default.removeItem(atPath: wrapperScriptPath) }
        }

        if diff.isEmpty { return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)") }
        return HookInstaller.InstallResult(summary: "removed \(toolName) wrapper + alias", diff: diff)
    }

    func installState() -> HookInstallState {
        let scriptExists = FileManager.default.fileExists(atPath: wrapperScriptPath)
        let markerInAnyRC = shellRCPaths.contains { rcContains(marker, at: $0) }
        guard markerInAnyRC || scriptExists else { return .notInstalled }
        // Both rc files should carry the marker and the wrapper script should exist.
        let allRCsHaveMarker = shellRCPaths.allSatisfy { rcContains(marker, at: $0) }
        guard allRCsHaveMarker && scriptExists else { return .modifiedExternally }
        let expectedAlias = "alias \(toolName)='\(wrapperScriptPath)'"
        let aliasCorrect = shellRCPaths.allSatisfy { rcContains(expectedAlias, at: $0) }
        return aliasCorrect ? .installed : .modifiedExternally
    }

    private func rcContains(_ needle: String, at path: String) -> Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains(needle) ?? false
    }
}
