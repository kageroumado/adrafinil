import Foundation

/// Installs (or removes) Adrafinil's opt-in background-shell hook: a `PreToolUse` hook matched to the
/// `Bash` tool that runs `acquire --if-background`, placing a TTL-bounded hold whenever the agent
/// launches a `run_in_background: true` command (see `BackgroundBashHold` for why this is the only
/// signal such a command gives us).
///
/// **Why this is a separate install path — the MCP sibling, not part of the core hook shape.** Like
/// the MCP server registration, this is a distinct, default-off capability toggled on its own. Folding
/// it into `NestedJSONHookShape` would rewrite the entire acquire/release/sub-agent hook set on every
/// flip of the setting — and for a trust-gated agent like Codex that would re-trigger the `/hooks`
/// approval. So it lives here, **scoped to the single `PreToolUse` event**: install upserts our one
/// handler (in a `Bash`-matcher group of our own), uninstall removes only it, and neither touches the
/// core hooks under `UserPromptSubmit`/`Stop`/`Subagent*`.
///
/// **The one coupling that remains** (mirrors the desync the app handles): the *core*
/// `NestedJSONHookShape.uninstall` strips every Adrafinil-tagged handler from every event, including
/// this one, so disconnecting an agent drops the background hook too. Core *install* leaves
/// `PreToolUse` untouched, so a plain reconnect preserves it; but a disconnect→reconnect cycle loses
/// it, which is why the app re-applies it on connect when the setting is on
/// (`LiveAgentHooksProvider.install`).
///
/// ```json
/// { "hooks": { "PreToolUse": [ { "matcher": "Bash",
///     "hooks": [ { "type": "command", "command": "adrafinil acquire … --if-background --ttl …", "_adrafinil": true } ] } ] } }
/// ```
struct BackgroundBashHookShape {
    let configPath: String
    /// The `PreToolUse` matcher narrowing the hook to the shell tool (Claude Code matches it against
    /// `tool_name`, so `"Bash"` fires only for the Bash tool).
    let matcher: String
    /// The `acquire … --if-background --ttl …` command the handler runs.
    let command: String

    /// The single event this shape owns. Kept deliberately narrow — the core hooks live elsewhere.
    private static let event = "PreToolUse"

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        merge(into: &hooks)
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        return HookInstaller.InstallResult(summary: "wired \(Self.event)(\(matcher)) background-shell hook", diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var hooks = existing["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        strip(from: &hooks)
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed background-shell hook", diff: diff)
    }

    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            guard let hooks = dict["hooks"] as? [String: Any],
                  let arr = hooks[Self.event] as? [[String: Any]],
                  let installed = Self.command(in: arr) else { return .notInstalled }
            return installed == command ? .installed : .modifiedExternally
        }
    }

    // MARK: - Entry helpers (scoped to the single PreToolUse event)

    /// Inserts (or repairs) our handler under `PreToolUse`, in a `matcher`-narrowed group of our own.
    /// Idempotent and in-place: an existing Adrafinil handler is rewritten to the canonical form (so a
    /// stale `--ttl` upgrades on reinstall), while any user handlers sharing the event survive.
    private func merge(into hooks: inout [String: Any]) {
        var arr = (hooks[Self.event] as? [[String: Any]]) ?? []
        let canonicalHandler: [String: Any] = ["type": "command", "command": command, "_adrafinil": true]
        if let gIdx = arr.firstIndex(where: { Self.entryReferencesAdrafinil($0) }) {
            var group = arr[gIdx]
            var inner = (group["hooks"] as? [[String: Any]]) ?? []
            if let hIdx = inner.firstIndex(where: { Self.handlerIsOurs($0) }) {
                inner[hIdx] = canonicalHandler
            } else {
                inner.append(canonicalHandler)
            }
            group["hooks"] = inner
            group["matcher"] = matcher
            arr[gIdx] = group
        } else {
            arr.append(["matcher": matcher, "hooks": [canonicalHandler]])
        }
        hooks[Self.event] = arr
    }

    /// Removes our handler from `PreToolUse`, leaving the user's own hooks there untouched — a group
    /// is dropped only once it holds no other handlers, and the event key once it holds no groups.
    private func strip(from hooks: inout [String: Any]) {
        guard let arr = hooks[Self.event] as? [[String: Any]] else { return }
        let pruned: [[String: Any]] = arr.compactMap { entry in
            guard Self.entryReferencesAdrafinil(entry) else { return entry }
            var group = entry
            var inner = (group["hooks"] as? [[String: Any]]) ?? []
            inner.removeAll { Self.handlerIsOurs($0) }
            if inner.isEmpty { return nil }
            group["hooks"] = inner
            return group
        }
        if pruned.isEmpty { hooks[Self.event] = nil } else { hooks[Self.event] = pruned }
    }

    private static func entryReferencesAdrafinil(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { handlerIsOurs($0) }
    }

    private static func handlerIsOurs(_ handler: [String: Any]) -> Bool {
        (handler["_adrafinil"] as? Bool) == true
            || ConfigFileIO.commandInvokesAdrafinilCLI(handler["command"] as? String)
    }

    private static func command(in arr: [[String: Any]]) -> String? {
        for entry in arr {
            if let inner = entry["hooks"] as? [[String: Any]],
               let cmd = inner.first(where: { handlerIsOurs($0) })?["command"] as? String {
                return cmd
            }
        }
        return nil
    }
}
