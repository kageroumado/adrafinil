import Foundation

/// Codex's `hooks.json` format (verified on-device against npm `@openai/codex` and the official
/// `figma` marketplace plugin's own `hooks.json`): each event maps to an array of **matcher
/// groups**, and each group wraps an inner `hooks` array of `{ "type": "command", "command": … }`
/// handlers — the *same* nested shape Claude Code uses.
///
/// ```json
/// { "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "adrafinil acquire …" } ] } ],
///              "Stop":            [ { "hooks": [ { "type": "command", "command": "adrafinil release …" } ] } ] } }
/// ```
///
/// > An earlier note claimed Codex used a *flat* `[{ "type": "command", … }]` array (no group
/// > wrapper). That was wrong: it silently ignores the flat form — `/hooks` lists nothing — and
/// > the nested matcher-group shape above is what it actually parses. `matcher` is omitted here: it
/// > narrows *which tool* a Pre/PostToolUse hook fires for, and these lifecycle events have no tool.
///
/// **Acquire on `UserPromptSubmit`, release on `Stop`.** Codex's `Stop` hook fires at turn
/// completion — the model is done and control returns to the user (`run_turn_stop_hooks` runs when
/// `!needs_follow_up`; verified in codex-rs `session/turn.rs`). Bracketing each turn with
/// acquire→release mirrors Claude Code exactly: the Mac is kept awake only while a turn is running,
/// and the next `UserPromptSubmit` re-acquires. `Stop` carries `session_id` on stdin (the same field
/// acquire keys on), so the release targets the exact `<tool>:<session_id>` hold. An Esc-interrupt is
/// the one turn-end that skips `Stop` (the abort short-circuits it) — covered, as for Claude, by the
/// daemon's CPU-idle sweep and process-exit watcher. A prior version released only via those nets and
/// missed turn-end entirely, leaving a hold pinned until the 24h backstop on installs whose process
/// the daemon couldn't watch (e.g. Homebrew's triple-suffixed binary name).
///
/// Two Codex-specific constraints shape this type:
///
/// 1. **No marker key.** Codex deserializes handlers strictly, so an extra `_adrafinil` field risks an
///    "unexpected key" rejection (the figma example carries only `type`+`command`). We identify our
///    own handlers by their `command` containing `adrafinil` instead of tagging them.
/// 2. **Preserve trust.** Trust is *not* stored in `hooks.json` — when the user trusts our hooks via
///    `/hooks`, Codex records `[hooks.state."<path>:<event>:<group>:<handler>"] trusted_hash = …` in
///    `config.toml`, keyed per handler by its position **and** a hash of its command. So re-installing
///    must keep each handler at a stable index with an unchanged command, or the key/hash no longer
///    matches and the user must re-approve. We therefore leave a correct handler untouched (preserving
///    any sibling keys), only rewrite one whose command drifted, and append a fresh group when absent.
///    Each event is trusted independently, so adding the `Stop` handler asks the user to trust only
///    that new handler — the existing `UserPromptSubmit` trust is untouched.
struct CodexHookShape {
    let configPath: String
    let acquireEvent: String
    let acquireCommand: String
    /// Release-hook event (Codex's `Stop`) and the command it runs, or nil to release solely via the
    /// daemon's process-exit/CPU-idle nets. Both must be set together.
    var releaseEvent: String?
    var releaseCommand: String?
    /// Events Adrafinil used to wire but no longer does. Install strips any adrafinil-owned handler
    /// from them so upgrading self-heals — e.g. Codex moved from `SessionStart` (skipped on resume)
    /// to `UserPromptSubmit`, and a lingering `SessionStart` → acquire would otherwise double-fire.
    var obsoleteEvents: [String] = []

    /// The `(event, command)` handlers we manage, in install order. The acquire handler always; the
    /// release handler only when both `releaseEvent` and `releaseCommand` are set.
    private var managedHandlers: [(event: String, command: String)] {
        var handlers = [(acquireEvent, acquireCommand)]
        if let releaseEvent, let releaseCommand { handlers.append((releaseEvent, releaseCommand)) }
        return handlers
    }

    private var managedEvents: Set<String> {
        Set(managedHandlers.map(\.event))
    }

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]

        for (event, command) in managedHandlers {
            Self.mergeOurHandler(into: &hooks, event: event, command: command)
        }
        let managed = managedEvents
        for stale in obsoleteEvents where !managed.contains(stale) {
            Self.stripOurHandlers(from: &hooks, event: stale)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        let wired = releaseEvent.map { "\(acquireEvent) acquire + \($0) release hooks" }
            ?? "\(acquireEvent) hook (release via process-exit watcher)"
        return HookInstaller.InstallResult(
            summary: "wired \(wired); trust it in Codex with /hooks",
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
        // Strip our handlers from every event — including ones the user may have moved them to.
        for ev in hooks.keys {
            Self.stripOurHandlers(from: &hooks, event: ev)
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed Codex hook entries", diff: diff)
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
            // Every managed handler must be present with its canonical command. A missing or drifted
            // one (e.g. upgrading from a build that predated the `Stop` release) is a partial install.
            let allManagedInstalled = managedHandlers.allSatisfy { event, command in
                Self.ourCommand(in: hooks, event: event) == command
            }
            guard allManagedInstalled else {
                return anyOurs ? .modifiedExternally : .notInstalled
            }
            let managed = managedEvents
            let hasObsolete = obsoleteEvents.contains { stale in
                !managed.contains(stale) && (hooks[stale] as? [[String: Any]])?.contains { Self.groupIsOurs($0) } == true
            }
            // Trust (`trusted_hash` in config.toml) is the user's step via `/hooks`, not something we
            // can apply, so present-and-correct handlers read as installed regardless of trust state.
            return hasObsolete ? .modifiedExternally : .installed
        }
    }

    private static func handler(_ command: String) -> [String: Any] {
        ["type": "command", "command": command]
    }

    /// Inserts (or repairs) our handler under `event`, preserving trust: a correct handler is left
    /// untouched so the `config.toml` trust hash keeps matching; only a drifted command is rewritten
    /// (keeping any sibling keys Codex added), and a fresh group is appended when ours is absent.
    private static func mergeOurHandler(into hooks: inout [String: Any], event: String, command: String) {
        var groups = (hooks[event] as? [[String: Any]]) ?? []
        if let gIdx = groups.firstIndex(where: { groupIsOurs($0) }) {
            var group = groups[gIdx]
            var handlers = (group["hooks"] as? [[String: Any]]) ?? []
            if let hIdx = handlers.firstIndex(where: { handlerIsOurs($0) }) {
                if (handlers[hIdx]["command"] as? String) != command {
                    var repaired = handlers[hIdx]
                    repaired["type"] = "command"
                    repaired["command"] = command
                    handlers[hIdx] = repaired
                    group["hooks"] = handlers
                    groups[gIdx] = group
                }
            } else {
                handlers.append(handler(command))
                group["hooks"] = handlers
                groups[gIdx] = group
            }
        } else {
            groups.append(["hooks": [handler(command)]])
        }
        hooks[event] = groups
    }

    /// The command of our handler under `event`, or nil if we have none there.
    private static func ourCommand(in hooks: [String: Any], event: String) -> String? {
        guard let groups = hooks[event] as? [[String: Any]],
              let group = groups.first(where: { groupIsOurs($0) }),
              let handlers = group["hooks"] as? [[String: Any]],
              let ours = handlers.first(where: { handlerIsOurs($0) }) else {
            return nil
        }
        return ours["command"] as? String
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
