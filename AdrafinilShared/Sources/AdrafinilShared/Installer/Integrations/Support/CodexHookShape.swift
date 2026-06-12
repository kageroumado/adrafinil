import Foundation

/// Codex's `hooks.json` format (verified on-device against npm `@openai/codex` 0.135.0 and the
/// official `figma` marketplace plugin's own `hooks.json`): each event maps to an array of **matcher
/// groups**, and each group wraps an inner `hooks` array of `{ "type": "command", "command": … }`
/// handlers — the *same* nested shape Claude Code uses.
///
/// ```json
/// { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "adrafinil acquire …" } ] } ] } }
/// ```
///
/// > An earlier note claimed Codex used a *flat* `[{ "type": "command", … }]` array (no group
/// > wrapper). That was wrong: 0.135.0 silently ignores the flat form — `/hooks` lists nothing — and
/// > the nested matcher-group shape above is what it actually parses. `matcher` is omitted here: it
/// > narrows *which tool* a Pre/PostToolUse hook fires for, and `SessionStart` has no tool to match.
///
/// Two Codex-specific constraints shape this type:
///
/// 1. **No marker key.** Codex deserializes handlers strictly, so an extra `_adrafinil` field risks an
///    "unexpected key" rejection (the figma example carries only `type`+`command`). We identify our
///    own handler by its `command` containing `adrafinil` instead of tagging it.
/// 2. **Preserve trust.** Trust is *not* stored in `hooks.json` — when the user trusts our hook via
///    `/hooks`, Codex records `[hooks.state."<path>:<event>:<group>:<handler>"] trusted_hash = …` in
///    `config.toml`, keyed by the handler's position **and** a hash of its command. So re-installing
///    must keep our handler at a stable index with an unchanged command, or the key/hash no longer
///    matches and the user must re-approve. We therefore leave a correct handler untouched (preserving
///    any sibling keys), only rewrite one whose command drifted, and append a fresh group when absent.
struct CodexHookShape {
    let configPath: String
    let event: String
    let command: String
    /// Events Adrafinil used to wire but no longer does. Install strips any adrafinil-owned handler
    /// from them so upgrading self-heals — e.g. Codex moved from `SessionStart` (skipped on resume)
    /// to `UserPromptSubmit`, and a lingering `SessionStart` → acquire would otherwise double-fire.
    var obsoleteEvents: [String] = []

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        var groups = (hooks[event] as? [[String: Any]]) ?? []

        if let gIdx = groups.firstIndex(where: { Self.groupIsOurs($0) }) {
            var group = groups[gIdx]
            var handlers = (group["hooks"] as? [[String: Any]]) ?? []
            if let hIdx = handlers.firstIndex(where: { Self.handlerIsOurs($0) }) {
                // Leave a correct handler as-is so the `config.toml` trust hash keeps matching; only
                // repair a drifted command, preserving any sibling keys Codex may have added.
                if (handlers[hIdx]["command"] as? String) != command {
                    var repaired = handlers[hIdx]
                    repaired["type"] = "command"
                    repaired["command"] = command
                    handlers[hIdx] = repaired
                    group["hooks"] = handlers
                    groups[gIdx] = group
                }
            } else {
                handlers.append(Self.handler(command))
                group["hooks"] = handlers
                groups[gIdx] = group
            }
        } else {
            groups.append(["hooks": [Self.handler(command)]])
        }
        hooks[event] = groups
        for stale in obsoleteEvents where stale != event {
            Self.stripOurHandlers(from: &hooks, event: stale)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        return HookInstaller.InstallResult(
            summary: "wired \(event) hook (release via process-exit watcher); trust it in Codex with /hooks",
            diff: diff,
        )
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var hooks = existing["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        // Strip our handler from every event — including one the user may have moved it to.
        for ev in hooks.keys {
            Self.stripOurHandlers(from: &hooks, event: ev)
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed Codex hook entry", diff: diff)
    }

    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            guard let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }
            // Any of our handlers anywhere — under an obsolete event or one the user moved it
            // to — is a partial install, never `.notInstalled`.
            let anyOurs = hooks.values.contains { value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.contains { Self.groupIsOurs($0) }
            }
            guard let groups = hooks[event] as? [[String: Any]],
                  let group = groups.first(where: { Self.groupIsOurs($0) }),
                  let handlers = group["hooks"] as? [[String: Any]],
                  let ours = handlers.first(where: { Self.handlerIsOurs($0) }) else {
                return anyOurs ? .modifiedExternally : .notInstalled
            }
            let hasObsolete = obsoleteEvents.contains { stale in
                stale != event && (hooks[stale] as? [[String: Any]])?.contains { Self.groupIsOurs($0) } == true
            }
            // Trust (`trusted_hash` in config.toml) is the user's step via `/hooks`, not something we can
            // apply, so a present-and-correct handler reads as installed regardless of trust state.
            return ((ours["command"] as? String) == command && !hasObsolete) ? .installed : .modifiedExternally
        }
    }

    private static func handler(_ command: String) -> [String: Any] {
        ["type": "command", "command": command]
    }

    /// Removes our handler from every group under `event`, dropping a group left with no handlers but
    /// keeping groups that still hold the user's own hooks. No-op when the event is absent.
    private static func stripOurHandlers(from hooks: inout [String: Any], event: String) {
        guard let groups = hooks[event] as? [[String: Any]] else { return }
        let pruned: [[String: Any]] = groups.compactMap { group in
            guard groupIsOurs(group) else { return group }
            var g = group
            var handlers = (g["hooks"] as? [[String: Any]]) ?? []
            handlers.removeAll { handlerIsOurs($0) }
            if handlers.isEmpty { return nil }
            g["hooks"] = handlers
            return g
        }
        // Drop the event key entirely once nothing is left under it, so uninstall leaves no empty
        // `"<event>": []` residue in the user's hooks.json.
        if pruned.isEmpty { hooks[event] = nil } else { hooks[event] = pruned }
    }

    /// A group is ours when its inner `hooks` array holds a handler whose command references our CLI.
    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains(where: handlerIsOurs)
    }

    private static func handlerIsOurs(_ handler: [String: Any]) -> Bool {
        ConfigFileIO.commandInvokesAdrafinilCLI(handler["command"] as? String)
    }
}
