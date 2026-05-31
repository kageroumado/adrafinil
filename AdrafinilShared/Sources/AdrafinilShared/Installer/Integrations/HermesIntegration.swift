import Foundation

/// Hermes (NousResearch/hermes-agent): a **shell hook** declared in `~/.hermes/config.yaml` under a
/// `hooks:` map, plus an approval in `~/.hermes/shell-hooks-allowlist.json`.
///
/// Verified against an installed Hermes on a real device: of its three hook systems, shell hooks
/// are the right fit — declared in `config.yaml`, they run in both CLI and Gateway and pipe a JSON
/// payload (with `session_id`) to the command's **stdin**, which our CLI already reads.
/// `on_session_start`/`on_session_end` are valid hook events. The command must be allowlisted
/// (first-use consent), matched by exact (event, command); without it the hooks are silently skipped.
/// Its other two hook systems — Python plugins and the gateway-only `HOOK.yaml` — don't fit.
struct HermesIntegration: AgentIntegration {
    let agent = AgentKind.hermes

    private static let markerStart = "  # >>> adrafinil (managed)"
    private static let markerEnd = "  # <<< adrafinil"

    private func configPath(_ ctx: HookContext) -> String { "\(ctx.homeRoot)/.hermes/config.yaml" }
    private func allowlistPath(_ ctx: HookContext) -> String { "\(ctx.homeRoot)/.hermes/shell-hooks-allowlist.json" }

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.hermes")
    }

    /// The post-YAML command string — also the exact string stored in the allowlist. The CLI path
    /// is shell-quoted so Hermes's `shlex.split` keeps a spaced path as a single arg; the session id
    /// comes from the hook's stdin `session_id`, so no positional key is needed.
    private func command(_ op: String, cliPath: String) -> String {
        let cli = cliPath.contains("'") ? "\"\(cliPath)\"" : "'\(cliPath)'"
        return "\(cli) \(op) --tool hermes"
    }

    /// The `hooks:` block we manage, bracketed by comment markers for clean removal.
    private func hookBlock(cliPath: String) -> String {
        """
        hooks:
        \(Self.markerStart)
          on_session_start:
            - command: "\(command("acquire", cliPath: cliPath))"
          on_session_end:
            - command: "\(command("release", cliPath: cliPath))"
        \(Self.markerEnd)
        """
    }

    func install(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let cfgPath = configPath(ctx)
        let existing = (try? String(contentsOfFile: cfgPath, encoding: .utf8)) ?? ""
        var summary = "wired Hermes on_session_start/on_session_end shell hooks"
        var diff = ""

        if existing.contains(Self.markerStart) {
            summary = "already installed"
        } else if existing.contains("hooks: {}") {
            // Fresh/default config: replace the empty hooks map with our block.
            let updated = existing.replacingOccurrences(of: "hooks: {}", with: hookBlock(cliPath: ctx.cliPath))
            if !dryRun { try updated.write(toFile: cfgPath, atomically: true, encoding: .utf8) }
            diff += "~ \(cfgPath): set hooks.on_session_start/on_session_end\n"
        } else if !existing.contains("\nhooks:") && !existing.hasPrefix("hooks:") {
            // No hooks map yet: append one.
            let updated = (existing.isEmpty ? "" : existing + "\n") + hookBlock(cliPath: ctx.cliPath) + "\n"
            if !dryRun { try ConfigFileIO.ensureParentDir(of: cfgPath); try updated.write(toFile: cfgPath, atomically: true, encoding: .utf8) }
            diff += "+ \(cfgPath): hooks block\n"
        } else {
            // An existing populated `hooks:` map — don't risk a blind YAML merge.
            summary = "Hermes config already has a hooks: section — add on_session_start/on_session_end manually (see docs)"
        }

        // Allowlist both commands so the hooks run without a first-use TTY prompt (JSON — safe to merge).
        if !dryRun { try addAllowlistApprovals(ctx) }
        diff += "~ \(allowlistPath(ctx)): approve acquire/release"
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let cfgPath = configPath(ctx)
        var diff = ""
        if let text = try? String(contentsOfFile: cfgPath, encoding: .utf8),
           let sRange = text.range(of: Self.markerStart),
           let eRange = text.range(of: Self.markerEnd) {
            // Remove our marked block. If it leaves `hooks:` childless, normalise back to `hooks: {}`.
            let lineStart = text.range(of: "\n", options: .backwards, range: text.startIndex..<sRange.lowerBound)?.upperBound ?? sRange.lowerBound
            let lineEnd = text.range(of: "\n", range: eRange.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            var updated = text
            updated.removeSubrange(lineStart..<lineEnd)
            updated = updated.replacingOccurrences(of: "hooks:\n", with: "hooks: {}\n")
            if !dryRun { try updated.write(toFile: cfgPath, atomically: true, encoding: .utf8) }
            diff += "~ \(cfgPath): removed adrafinil hooks\n"
        }
        if !dryRun { try removeAllowlistApprovals(ctx) }
        diff += "~ \(allowlistPath(ctx)): revoke adrafinil approvals"
        return diff.isEmpty ? HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
                            : HookInstaller.InstallResult(summary: "removed Hermes hooks", diff: diff)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        guard let text = try? String(contentsOfFile: configPath(ctx), encoding: .utf8) else { return .notInstalled }
        let hasAcquire = text.contains(command("acquire", cliPath: ctx.cliPath))
        let hasRelease = text.contains(command("release", cliPath: ctx.cliPath))
        guard hasAcquire || hasRelease else { return .notInstalled }
        // Installed iff both commands are present AND both are allowlisted (else the hooks are skipped).
        let allowed = isAllowlisted(command("acquire", cliPath: ctx.cliPath), event: "on_session_start", ctx)
                   && isAllowlisted(command("release", cliPath: ctx.cliPath), event: "on_session_end", ctx)
        return (hasAcquire && hasRelease && allowed) ? .installed : .modifiedExternally
    }

    // MARK: - Allowlist: {"approvals": [{"event": …, "command": …}, …]}

    private func approvals(_ ctx: HookContext) -> [(event: String, command: String)] {
        [("on_session_start", command("acquire", cliPath: ctx.cliPath)),
         ("on_session_end", command("release", cliPath: ctx.cliPath))]
    }

    private func loadAllowlist(_ ctx: HookContext) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: allowlistPath(ctx))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let approvals = obj["approvals"] as? [[String: Any]] else { return [] }
        return approvals
    }

    private func isAllowlisted(_ command: String, event: String, _ ctx: HookContext) -> Bool {
        loadAllowlist(ctx).contains { ($0["event"] as? String) == event && ($0["command"] as? String) == command }
    }

    private func writeAllowlist(_ approvals: [[String: Any]], _ ctx: HookContext) throws {
        try ConfigFileIO.ensureParentDir(of: allowlistPath(ctx))
        let data = try JSONSerialization.data(withJSONObject: ["approvals": approvals], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: allowlistPath(ctx)), options: .atomic)
    }

    private func addAllowlistApprovals(_ ctx: HookContext) throws {
        var current = loadAllowlist(ctx)
        for a in approvals(ctx) where !isAllowlisted(a.command, event: a.event, ctx) {
            current.append(["event": a.event, "command": a.command])
        }
        try writeAllowlist(current, ctx)
    }

    private func removeAllowlistApprovals(_ ctx: HookContext) throws {
        let filtered = loadAllowlist(ctx).filter { ($0["command"] as? String)?.contains("--tool hermes") != true }
        try writeAllowlist(filtered, ctx)
    }
}
