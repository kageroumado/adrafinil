import Foundation

/// The nested hook shape shared by Claude Code and Gemini CLI: a single JSON file with a top-level
/// `hooks` dict keyed by event name, each value an array of entries that themselves wrap an inner
/// `hooks` array of `{"type": "command", "command": …}` objects. (Codex uses a flatter variant — see
/// `CodexHookShape`.)
///
/// ```json
/// { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "adrafinil acquire …" } ] } ] } }
/// ```
///
/// Adrafinil's own entries are tagged with `_adrafinil: true` so install is self-healing (it
/// replaces a stale entry in place) and uninstall removes only ours, leaving the user's hooks intact.
/// Repairs operate on the inner *handler*, never the whole group, so user handlers sharing a group
/// with ours survive every install/uninstall.
struct NestedJSONHookShape {
    /// An extra release hook on its own event, narrowed by a `matcher`. Claude Code uses one for
    /// `Notification` matched to `idle_prompt`: an Esc-interrupt skips `Stop`, so without this the
    /// hold would linger until the daemon's CPU-idle backstop. Claude fires an `idle_prompt`
    /// Notification ~60s after the agent goes idle (the `finally` that records query-completion runs
    /// on interrupt too), so releasing on it frees the Mac shortly after an interrupted turn.
    struct MatchedRelease {
        let event: String
        let matcher: String
    }

    let configPath: String
    let startEvent: String
    /// Release-hook event, or nil to release via the daemon's process-exit watcher instead
    /// (Codex's `Stop` fires per-turn, not at session end, so it has no usable end hook).
    let endEvent: String?
    let acquireCommand: String
    let releaseCommand: String
    /// Events this integration used to wire but no longer does. Install proactively strips any
    /// Adrafinil-tagged entry from them so upgrading self-heals — e.g. Claude Code moved from
    /// `SessionStart`/`SessionEnd` (session-scoped) to `UserPromptSubmit`/`Stop` (activity-scoped),
    /// and a lingering `SessionStart` → acquire would otherwise re-introduce the whole-session hold.
    var obsoleteEvents: [String] = []
    /// Additional `releaseCommand` hooks beyond `endEvent`, each on its own event with a matcher.
    var extraReleases: [MatchedRelease] = []

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        merge(into: &hooks, event: startEvent, command: acquireCommand)
        if let endEvent { merge(into: &hooks, event: endEvent, command: releaseCommand) }
        for extra in extraReleases {
            merge(into: &hooks, event: extra.event, command: releaseCommand, matcher: extra.matcher)
        }
        let managed = Set([startEvent, endEvent].compactMap(\.self) + extraReleases.map(\.event))
        for event in obsoleteEvents where !managed.contains(event) {
            stripAdrafinil(from: &hooks, event: event)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        let releaseEvents = ([endEvent].compactMap(\.self) + extraReleases.map(\.event)).joined(separator: "+")
        let summary = releaseEvents.isEmpty
            ? "wired \(startEvent) hook (release via process-exit watcher)"
            : "wired \(startEvent) acquire + \(releaseEvents) release hooks"
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var hooks = existing["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        // Clean our entry from every event that has one — including events the user may have
        // moved our entry to — not just the ones we currently manage.
        for event in hooks.keys {
            stripAdrafinil(from: &hooks, event: event)
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: "removed hook entries", diff: diff)
    }

    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            .notInstalled
        case .unparseable:
            .configUnreadable
        case let .object(dict):
            installState(of: dict)
        }
    }

    private func installState(of dict: [String: Any]) -> HookInstallState {
        guard let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }

        // Any adrafinil entry anywhere — under managed events, obsolete events, or an event the
        // user moved it to — means our hooks are (partially) present. A partial or drifted set
        // must never read as `.notInstalled`: live entries would be invisible to the UI, with no
        // "Disconnect" offered for them.
        let anyOurs = hooks.values.contains { value in
            guard let arr = value as? [[String: Any]] else { return false }
            return arr.contains { Self.entryReferencesAdrafinil($0) }
        }

        guard let startArr = hooks[startEvent] as? [[String: Any]],
              let installedAcquire = Self.command(in: startArr) else {
            return anyOurs ? .modifiedExternally : .notInstalled
        }

        // A leftover Adrafinil entry under an event we've migrated away from means the config is in
        // a stale, mixed state — report it as externally modified so the UI nudges a reinstall, which
        // strips the obsolete entry.
        let hasObsolete = obsoleteEvents.contains { event in
            (hooks[event] as? [[String: Any]]).map { Self.command(in: $0) != nil } ?? false
        }

        // Every extra matched-release hook must carry our release command, or the install is partial
        // (e.g. upgrading from a build that predated the Notification/idle_prompt release).
        let extrasInstalled = extraReleases.allSatisfy { extra in
            (hooks[extra.event] as? [[String: Any]]).flatMap { Self.command(in: $0) } == releaseCommand
        }

        guard let endEvent else {
            let ok = installedAcquire == acquireCommand && extrasInstalled && !hasObsolete
            return ok ? .installed : .modifiedExternally
        }
        guard let endArr = hooks[endEvent] as? [[String: Any]],
              let installedRelease = Self.command(in: endArr) else { return .modifiedExternally }

        let matches = installedAcquire == acquireCommand && installedRelease == releaseCommand
            && extrasInstalled && !hasObsolete
        return matches ? .installed : .modifiedExternally
    }

    // MARK: - Entry helpers

    /// Inserts (or repairs) our handler under `event`. Idempotent: if an Adrafinil handler already
    /// exists it's replaced with the canonical form *in place* — only the handler, so any user
    /// handlers sharing the group survive — and re-running install upgrades a stale command
    /// instead of leaving the broken one. A non-Adrafinil entry is untouched.
    private func merge(into hooks: inout [String: Any], event: String, command: String, matcher: String? = nil) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
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
            if let matcher { group["matcher"] = matcher }
            arr[gIdx] = group
        } else {
            var group: [String: Any] = ["hooks": [canonicalHandler]]
            if let matcher { group["matcher"] = matcher }
            arr.append(group)
        }
        hooks[event] = arr
    }

    /// Removes our handlers from one event's array, leaving the user's own hooks untouched — a
    /// group is dropped only once it holds no other handlers. Shared by uninstall and install's
    /// obsolete-event cleanup.
    private func stripAdrafinil(from hooks: inout [String: Any], event: String) {
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
        // Drop the event key once empty so uninstall leaves no `"<event>": []` residue.
        if pruned.isEmpty { hooks[event] = nil } else { hooks[event] = pruned }
    }

    private static func entryReferencesAdrafinil(_ entry: [String: Any]) -> Bool {
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { handlerIsOurs($0) }
        }
        return ConfigFileIO.commandInvokesAdrafinilCLI(entry["command"] as? String)
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
