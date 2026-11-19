import Foundation

/// Installs (or removes) Adrafinil's opt-in background-shell hooks: a `PreToolUse` hook matched to the
/// `Bash` and `Monitor` tools that runs `acquire --if-background`, placing a hold whenever the agent
/// launches a `run_in_background: true` command or a Monitor, and a `PostToolUse` hook matched to
/// `Bash` that runs `acquire --bind-background`, binding that hold to the command's shell (see
/// `BackgroundBashHold` for why both are needed).
///
/// **Why this is a separate install path — the MCP sibling, not part of the core hook shape.** Like
/// the MCP server registration, this is a distinct, default-off capability toggled on its own. Folding
/// it into `NestedJSONHookShape` would rewrite the entire acquire/release/sub-agent hook set on every
/// flip of the setting — and for a trust-gated agent like Codex that would re-trigger the `/hooks`
/// approval. So it lives here, **scoped to the two events it owns**: install upserts our handler in
/// each (in a matcher-narrowed group of our own), uninstall removes only those, and neither touches the
/// core hooks under `UserPromptSubmit`/`Stop`/`Subagent*`.
///
/// **The one coupling that remains** (mirrors the desync the app handles): the *core*
/// `NestedJSONHookShape.uninstall` strips every Adrafinil-tagged handler from every event, including
/// these, so disconnecting an agent drops the background hooks too. Core *install* leaves them
/// untouched, so a plain reconnect preserves them; but a disconnect→reconnect cycle loses them, which
/// is why the app re-applies them on connect when the setting is on (`LiveAgentHooksProvider.install`).
///
/// ```json
/// { "hooks": {
///     "PreToolUse":  [ { "matcher": "Bash|Monitor", "hooks": [ { "type": "command",
///         "command": "adrafinil acquire … --if-background --ttl …", "_adrafinil": true } ] } ],
///     "PostToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command",
///         "command": "adrafinil acquire … --bind-background --ttl …", "_adrafinil": true } ] } ] } }
/// ```
struct BackgroundBashHookShape {
    /// One handler this shape owns: the event it runs under, the matcher narrowing it (Claude Code
    /// matches it as a regex against `tool_name`), and the command it runs.
    struct Wiring {
        let event: String
        let matcher: String
        let command: String
    }

    let configPath: String
    /// The events this shape owns, in install order. Each is installed, read and stripped on its own.
    let wirings: [Wiring]

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        for wiring in wirings {
            merge(wiring, into: &hooks)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        let events = wirings.map { "\($0.event)(\($0.matcher))" }.joined(separator: " + ")
        return HookInstaller.InstallResult(summary: "wired \(events) background-shell hooks", diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var hooks = existing["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        for wiring in wirings {
            strip(event: wiring.event, from: &hooks)
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed background-shell hooks", diff: diff)
    }

    /// `.installed` only when every owned event carries our canonical handler; `.notInstalled` when
    /// none does. A partial install (an older build's `PreToolUse`-only one, say) reads as
    /// `.modifiedExternally`; the app's re-apply on connect (`LiveAgentHooksProvider.install`) repairs it.
    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            let hooks = dict["hooks"] as? [String: Any] ?? [:]
            let states = wirings.map { state(of: $0, in: hooks) }
            if states.allSatisfy({ $0 == .installed }) { return .installed }
            if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
            return .modifiedExternally
        }
    }

    // MARK: - Entry helpers (scoped to the events this shape owns)

    private enum WiringState {
        case installed
        case notInstalled
        case modified
    }

    /// Whether `wiring`'s event carries our handler in canonical form. The matcher counts too: an
    /// older build installed this hook for `Bash` alone.
    private func state(of wiring: Wiring, in hooks: [String: Any]) -> WiringState {
        guard let arr = hooks[wiring.event] as? [[String: Any]],
              let group = arr.first(where: { Self.entryReferencesAdrafinil($0) }),
              let installed = Self.command(in: [group]) else { return .notInstalled }
        return installed == wiring.command && group["matcher"] as? String == wiring.matcher ? .installed : .modified
    }

    /// Inserts (or repairs) our handler under `wiring.event`, in a `matcher`-narrowed group of our own.
    /// Idempotent and in-place: an existing Adrafinil handler is rewritten to the canonical form (so a
    /// stale `--ttl` upgrades on reinstall), while any user handlers sharing the event survive.
    private func merge(_ wiring: Wiring, into hooks: inout [String: Any]) {
        var arr = (hooks[wiring.event] as? [[String: Any]]) ?? []
        let canonicalHandler: [String: Any] = ["type": "command", "command": wiring.command, "_adrafinil": true]
        if let gIdx = arr.firstIndex(where: { Self.entryReferencesAdrafinil($0) }) {
            var group = arr[gIdx]
            var inner = (group["hooks"] as? [[String: Any]]) ?? []
            if let hIdx = inner.firstIndex(where: { Self.handlerIsOurs($0) }) {
                inner[hIdx] = canonicalHandler
            } else {
                inner.append(canonicalHandler)
            }
            group["hooks"] = inner
            group["matcher"] = wiring.matcher
            arr[gIdx] = group
        } else {
            arr.append(["matcher": wiring.matcher, "hooks": [canonicalHandler]])
        }
        hooks[wiring.event] = arr
    }

    /// Removes our handler from `event`, leaving the user's own hooks there untouched — a group is
    /// dropped only once it holds no other handlers, and the event key once it holds no groups.
    private func strip(event: String, from hooks: inout [String: Any]) {
        guard let arr = hooks[event] as? [[String: Any]] else { return }
        let pruned: [[String: Any]] = arr.compactMap { entry in
            guard Self.entryReferencesAdrafinil(entry) else { return entry }
            var group = entry
            var inner = (group["hooks"] as? [[String: Any]]) ?? []
            inner.removeAll { Self.handlerIsOurs($0) }
            if inner.isEmpty { return nil }
            group["hooks"] = inner
            return group
        }
        if pruned.isEmpty { hooks[event] = nil } else { hooks[event] = pruned }
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
