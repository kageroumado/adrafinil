import Foundation

/// Hermes (NousResearch/hermes-agent): a **shell hook** declared in `~/.hermes/config.yaml` under a
/// `hooks:` map, plus an approval in `~/.hermes/shell-hooks-allowlist.json`.
///
/// Verified against an installed Hermes on a real device: of its three hook systems, shell hooks
/// are the right fit — declared in `config.yaml`, they run in both CLI and Gateway and pipe a JSON
/// payload to the command's **stdin**. The command must be allowlisted (first-use consent), matched
/// by exact (event, command); without it the hooks are silently skipped. Its other two hook systems
/// — Python plugins and the gateway-only `HOOK.yaml` — don't fit.
///
/// Hermes is a 24/7 **gateway**: one shared process multiplexes every session, and its session hooks
/// are asymmetric — `on_session_start` fires once per new conversation (not on continuation) while
/// `on_session_end` fires at the end of *every* turn. So the naive start→acquire / end→release pair
/// under-protects multi-turn sessions (only the first turn gets a hold). We instead treat the gateway
/// as a single activity unit (`AgentKind.isGatewayScoped`): acquire on both `on_session_start` *and*
/// `pre_gateway_dispatch` (the latter fires once per incoming message, so a turn arriving after the
/// hold was released is re-protected), coalesced onto a fixed `hermes:gateway` hold carrying the
/// gateway PID. Release on `on_session_end` is the fast path back to sleep; the daemon's CPU-idle and
/// dead-process nets on the gateway tree are what actually make a missed/asymmetric end hook safe.
///
/// YAML is mutated with line-scoped string surgery, never a parse/serialize round-trip (which would
/// reorder and reformat the user's whole file). Every removal is recognizer-based so user content
/// survives even a damaged marker block.
struct HermesIntegration: AgentIntegration {
    let agent = AgentKind.hermes

    private static let markerStart = "  # >>> adrafinil (managed)"
    private static let markerEnd = "  # <<< adrafinil"
    /// Event keys our managed block declares, used to recognize our own lines during removal.
    private static let managedEventKeys = ["on_session_start:", "pre_gateway_dispatch:", "on_session_end:"]

    private func configPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.hermes/config.yaml"
    }
    private func allowlistPath(_ ctx: HookContext) -> String {
        "\(ctx.homeRoot)/.hermes/shell-hooks-allowlist.json"
    }

    func isDetected(_ ctx: HookContext) -> Bool {
        FileManager.default.fileExists(atPath: "\(ctx.homeRoot)/.hermes")
    }
    func primaryConfigPath(_ ctx: HookContext) -> String {
        configPath(ctx)
    }

    /// The post-YAML command string — also the exact string stored in the allowlist. The CLI path
    /// is shell-quoted so Hermes's `shlex.split` keeps a spaced path as a single arg; the session id
    /// comes from the hook's stdin `session_id`, so no positional key is needed.
    private func command(_ op: String, cliPath: String) -> String {
        let cli = cliPath.contains("'") ? "\"\(cliPath)\"" : "'\(cliPath)'"
        return "\(cli) \(op) --tool hermes"
    }

    /// The `hooks:` block we manage, bracketed by comment markers for clean removal. Acquire is wired
    /// on both `on_session_start` (new conversation) and `pre_gateway_dispatch` (every incoming
    /// gateway message), so a multi-turn session stays protected; release on `on_session_end`.
    private func hookBlock(cliPath: String) -> String {
        """
        hooks:
        \(Self.markerStart)
          on_session_start:
            - command: "\(command("acquire", cliPath: cliPath))"
          pre_gateway_dispatch:
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
        var wroteHooks = false

        let intact = existing.contains(Self.markerStart)
            && Self.activeLines(of: existing).contains { $0.contains(command("acquire", cliPath: ctx.cliPath)) }

        if intact {
            summary = "already installed"
            wroteHooks = true // Approvals may still need a top-up (e.g. a wiped allowlist).
        } else {
            // A stale block (the app moved, so the embedded CLI path drifted) is removed first,
            // then reinstalled fresh through the same paths as a clean config.
            var working = existing.contains(Self.markerStart) ? Self.removingManagedBlock(from: existing) : existing
            var lines = working.components(separatedBy: "\n")

            if let idx = lines.firstIndex(of: "hooks: {}") {
                // Fresh/default config: replace the empty top-level hooks map with our block.
                // Exact-line match only — a nested/indented `hooks: {}` or a `python_hooks: {}`
                // must never be rewritten.
                lines[idx] = hookBlock(cliPath: ctx.cliPath)
                working = lines.joined(separator: "\n")
                if !dryRun { try ConfigFileIO.writeString(working, to: cfgPath) }
                diff += "~ \(cfgPath): set hooks.on_session_start/on_session_end\n"
                wroteHooks = true
            } else if !lines.contains(where: { $0.hasPrefix("hooks:") }) {
                // No top-level hooks map yet: append one.
                let updated = (working.isEmpty ? "" : working + "\n") + hookBlock(cliPath: ctx.cliPath) + "\n"
                if !dryRun {
                    try ConfigFileIO.ensureParentDir(of: cfgPath)
                    try ConfigFileIO.writeString(updated, to: cfgPath)
                }
                diff += "+ \(cfgPath): hooks block\n"
                wroteHooks = true
            } else {
                // An existing populated `hooks:` map — don't risk a blind YAML merge.
                summary = "Hermes config already has a hooks: section — add on_session_start/on_session_end manually (see docs)"
            }
        }

        // Approvals are written only alongside hooks that exist — an approval for a command that
        // isn't in config.yaml is dead weight that survives uninstalls confusingly.
        if wroteHooks {
            if !dryRun { try reconcileAllowlistApprovals(ctx) }
            diff += "~ \(allowlistPath(ctx)): approve acquire/release"
        }
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    func uninstall(_ ctx: HookContext, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let cfgPath = configPath(ctx)
        var diff = ""
        if let text = try? String(contentsOfFile: cfgPath, encoding: .utf8), text.contains(Self.markerStart) {
            let updated = Self.removingManagedBlock(from: text)
            if !dryRun { try ConfigFileIO.writeString(updated, to: cfgPath) }
            diff += "~ \(cfgPath): removed adrafinil hooks\n"
        }
        if !dryRun { try removeAllowlistApprovals(ctx) }
        diff += "~ \(allowlistPath(ctx)): revoke adrafinil approvals"
        return diff.isEmpty ? HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
            : HookInstaller.InstallResult(summary: "removed Hermes hooks", diff: diff)
    }

    func installState(_ ctx: HookContext) -> HookInstallState {
        guard let text = try? String(contentsOfFile: configPath(ctx), encoding: .utf8) else { return .notInstalled }
        let active = Self.activeLines(of: text)
        let hasAcquire = active.contains { $0.contains(command("acquire", cliPath: ctx.cliPath)) }
        let hasRelease = active.contains { $0.contains(command("release", cliPath: ctx.cliPath)) }
        if !hasAcquire, !hasRelease {
            // Our marker block, or any adrafinil hook command (e.g. with a stale CLI path after
            // the app moved), means our wiring is present-but-broken — never `.notInstalled`,
            // which would offer "Connect" while dead hooks linger.
            let anyOurs = text.contains(Self.markerStart)
                || active.contains { ConfigFileIO.commandInvokesAdrafinilCLI($0) && $0.contains("--tool hermes") }
            return anyOurs ? .modifiedExternally : .notInstalled
        }
        // Installed iff the commands are present AND every (event, command) pair is allowlisted
        // (else that hook is silently skipped).
        let allowed = approvals(ctx).allSatisfy { isAllowlisted($0.command, event: $0.event, ctx) }
        return (hasAcquire && hasRelease && allowed) ? .installed : .modifiedExternally
    }

    // MARK: - YAML surgery

    /// Lines that Hermes would actually evaluate — comment lines (which include our own markers)
    /// don't count when checking whether a hook command is wired.
    private static func activeLines(of text: String) -> [String] {
        text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
    }

    /// Removes our managed block. Bounded by both markers when they're intact; when the end
    /// marker was deleted, only lines recognizably ours (our event keys, our command lines) are
    /// removed and removal stops at the first foreign line — the user's YAML after a damaged
    /// block is never swallowed. A `hooks:` line left genuinely childless (next line not
    /// indented) is restored to `hooks: {}`; a populated hooks map elsewhere is never touched.
    static func removingManagedBlock(from text: String) -> String {
        var kept: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            if line.contains(markerStart) { inBlock = true; continue }
            if line.contains(markerEnd) { inBlock = false; continue }
            if inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isOurs = managedEventKeys.contains { trimmed.hasPrefix($0) }
                    || (trimmed.hasPrefix("- command:") && trimmed.contains("adrafinil"))
                    || trimmed.isEmpty
                if isOurs { continue }
                inBlock = false
            }
            kept.append(line)
        }
        for i in kept.indices where kept[i] == "hooks:" {
            let next = i + 1 < kept.count ? kept[i + 1] : ""
            if next.isEmpty || !next.hasPrefix(" ") { kept[i] = "hooks: {}" }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Allowlist: {"approvals": [{"event": …, "command": …}, …]}

    private func approvals(_ ctx: HookContext) -> [(event: String, command: String)] {
        [
            ("on_session_start", command("acquire", cliPath: ctx.cliPath)),
            ("pre_gateway_dispatch", command("acquire", cliPath: ctx.cliPath)),
            ("on_session_end", command("release", cliPath: ctx.cliPath)),
        ]
    }

    /// The full allowlist document. Hermes owns this file and may add top-level keys beyond
    /// `approvals`; round-tripping the whole object preserves them.
    private func loadAllowlistDocument(_ ctx: HookContext) throws -> [String: Any] {
        try ConfigFileIO.readJSONForUpdate(allowlistPath(ctx)) ?? [:]
    }

    private func approvalEntries(of document: [String: Any]) -> [[String: Any]] {
        (document["approvals"] as? [[String: Any]]) ?? []
    }

    private func isAllowlisted(_ command: String, event: String, _ ctx: HookContext) -> Bool {
        guard let document = try? loadAllowlistDocument(ctx) else { return false }
        return approvalEntries(of: document).contains {
            ($0["event"] as? String) == event && ($0["command"] as? String) == command
        }
    }

    private func writeAllowlist(document: [String: Any], replacing before: [String: Any]?, _ ctx: HookContext) throws {
        try ConfigFileIO.ensureParentDir(of: allowlistPath(ctx))
        try ConfigFileIO.writeJSON(document, to: allowlistPath(ctx), replacing: before)
    }

    /// Adds approvals for the current commands and prunes ours that no longer match (a stale CLI
    /// path), leaving the user's own approvals untouched.
    private func reconcileAllowlistApprovals(_ ctx: HookContext) throws {
        let before = try ConfigFileIO.readJSONForUpdate(allowlistPath(ctx))
        var document = before ?? [:]
        let wanted = approvals(ctx)
        var entries = approvalEntries(of: document).filter { entry in
            guard let cmd = entry["command"] as? String,
                  ConfigFileIO.commandInvokesAdrafinilCLI(cmd), cmd.contains("--tool hermes") else { return true }
            return wanted.contains { $0.event == (entry["event"] as? String) && $0.command == cmd }
        }
        for a in wanted where !entries.contains(where: { ($0["event"] as? String) == a.event && ($0["command"] as? String) == a.command }) {
            entries.append(["event": a.event, "command": a.command])
        }
        document["approvals"] = entries
        try writeAllowlist(document: document, replacing: before, ctx)
    }

    private func removeAllowlistApprovals(_ ctx: HookContext) throws {
        let before = try ConfigFileIO.readJSONForUpdate(allowlistPath(ctx))
        guard let before else { return }
        var document = before
        document["approvals"] = approvalEntries(of: document).filter { entry in
            guard let cmd = entry["command"] as? String else { return true }
            return !(ConfigFileIO.commandInvokesAdrafinilCLI(cmd) && cmd.contains("--tool hermes"))
        }
        try writeAllowlist(document: document, replacing: before, ctx)
    }
}
