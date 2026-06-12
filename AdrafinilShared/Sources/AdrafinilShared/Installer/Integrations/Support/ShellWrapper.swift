import Foundation

/// Shell-alias integration for agents with no hook system (Aider, Cline). Writes a standalone
/// wrapper script (`~/.local/bin/<agent>-adrafinil`) that brackets the real tool with
/// `acquire`/`release`, and an alias in the user's shell rc files so the wrapper runs in place
/// of the bare tool.
///
/// rc files are the highest-value files this code touches, so every mutation is line-scoped and
/// recognizer-based: only lines that are provably ours (our markers, our alias) are ever removed.
/// In particular, a damaged block — the user deleted the end marker — must never cause everything
/// after the start marker to be treated as ours; that would truncate their rc file.
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

    /// Shell rc files that receive the alias. Only existing files are modified; when neither
    /// exists, `.zshrc` (the macOS default shell) is created.
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
    private var aliasLine: String {
        "alias \(toolName)='\(wrapperScriptPath)'"
    }
    private var rcBlock: String {
        "\(marker)\n\(aliasLine)\n\(endMarker)"
    }

    /// The wrapper script: acquire → run the real tool → release.
    private var canonicalScript: String {
        """
        #!/usr/bin/env bash
        \(quotedCLI) acquire $$ --tool \(toolName)
        \(toolName) "$@"
        status=$?
        \(quotedCLI) release $$ --tool \(toolName)
        exit $status
        """
    }

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        var diff = ""
        var changed = false

        let existingRCs = shellRCPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let targets = existingRCs.isEmpty ? [shellRCPaths[0]] : existingRCs
        for rcPath in targets {
            let current = (try? String(contentsOfFile: rcPath, encoding: .utf8)) ?? ""
            if current.contains(marker), current.contains(aliasLine) { continue }
            // Repair a drifted block (edited alias, stale wrapper path) by removing our lines
            // and appending a fresh block.
            var updated = current.contains(marker) ? removingOurLines(from: current) : current
            updated += "\n" + rcBlock + "\n"
            if !dryRun { try ConfigFileIO.writeString(updated, to: rcPath) }
            diff += "+ \(rcPath): \(aliasLine)\n"
            changed = true
        }

        let script = canonicalScript
        let existingScript = try? String(contentsOfFile: wrapperScriptPath, encoding: .utf8)
        if existingScript != script {
            // Covers both a missing script and one whose embedded CLI path drifted (the app
            // moved); the script is wholly ours, so rewriting is always safe.
            diff += "+ \(wrapperScriptPath) (wrapper script)\n"
            if !dryRun {
                try ConfigFileIO.ensureParentDir(of: wrapperScriptPath)
                try ConfigFileIO.writeString(script, to: wrapperScriptPath)
                chmod(wrapperScriptPath, 0o755)
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
            let updated = removingOurLines(from: current)
            if updated != current {
                diff += "- \(rcPath): removed alias block\n"
                if !dryRun { try ConfigFileIO.writeString(updated, to: rcPath) }
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
        let scriptContent = try? String(contentsOfFile: wrapperScriptPath, encoding: .utf8)
        let existingRCs = shellRCPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let rcsWithMarker = existingRCs.filter { rcContains(marker, at: $0) }

        guard !rcsWithMarker.isEmpty || scriptContent != nil else { return .notInstalled }

        // The wrapper script must match what we'd write (a drifted embedded CLI path silently
        // invokes a dead binary), at least one rc file must carry the alias, and every rc file
        // that has our marker must still have the alias intact.
        guard scriptContent == canonicalScript, !rcsWithMarker.isEmpty else { return .modifiedExternally }
        let aliasIntact = rcsWithMarker.allSatisfy { rcContains(aliasLine, at: $0) }
        return aliasIntact ? .installed : .modifiedExternally
    }

    /// Removes only lines that are provably ours: the markers, our alias (current or with a
    /// stale wrapper path), and the legacy single-line marker. User content always survives —
    /// even inside a damaged block whose end marker was deleted.
    private func removingOurLines(from content: String) -> String {
        let lines = content.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(marker) || trimmed.hasPrefix(endMarker) { return false }
            // Legacy single-line marker support (no end marker).
            if trimmed.hasPrefix("# adrafinil-"), trimmed.contains(toolName) { return false }
            if trimmed.hasPrefix("alias \(toolName)="), trimmed.contains("-adrafinil") { return false }
            return true
        }
        return lines.joined(separator: "\n")
    }

    private func rcContains(_ needle: String, at path: String) -> Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains(needle) ?? false
    }
}
