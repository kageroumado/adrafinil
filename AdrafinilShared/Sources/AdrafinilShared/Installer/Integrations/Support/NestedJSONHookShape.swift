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
        let before = ConfigFileIO.readJSON(configPath) ?? [:]
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
            try ConfigFileIO.writeJSON(after, to: configPath)
        }
        let releaseEvents = ([endEvent].compactMap(\.self) + extraReleases.map(\.event)).joined(separator: "+")
        let summary = releaseEvents.isEmpty
            ? "wired \(startEvent) hook (release via process-exit watcher)"
            : "wired \(startEvent) acquire + \(releaseEvents) release hooks"
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = ConfigFileIO.readJSON(configPath), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        // Clean our entry from this agent's current events, the events it has since migrated away
        // from (`obsoleteEvents`), plus the legacy `SessionEnd`/`Stop` events an earlier version may
        // have written.
        let events = Set([startEvent, endEvent].compactMap(\.self) + extraReleases.map(\.event) + obsoleteEvents + ["SessionEnd", "Stop"])
        for event in events {
            stripAdrafinil(from: &hooks, event: event)
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath) }
        return HookInstaller.InstallResult(summary: "removed hook entries", diff: diff)
    }

    func installState() -> HookInstallState {
        guard let dict = ConfigFileIO.readJSON(configPath),
              let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }

        guard let startArr = hooks[startEvent] as? [[String: Any]],
              let installedAcquire = Self.command(in: startArr) else { return .notInstalled }

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
              let installedRelease = Self.command(in: endArr) else { return .notInstalled }

        let matches = installedAcquire == acquireCommand && installedRelease == releaseCommand
            && extrasInstalled && !hasObsolete
        return matches ? .installed : .modifiedExternally
    }

    // MARK: - Entry helpers

    /// Inserts (or repairs) our entry under `event`. Idempotent: if an Adrafinil-tagged entry
    /// already exists it's *replaced* with the canonical form, so re-running install upgrades a
    /// stale command instead of leaving the broken one in place. A non-Adrafinil entry is untouched.
    private func merge(into hooks: inout [String: Any], event: String, command: String, matcher: String? = nil) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        var canonical: [String: Any] = [
            "hooks": [["type": "command", "command": command, "_adrafinil": true]],
        ]
        if let matcher { canonical["matcher"] = matcher }
        if let idx = arr.firstIndex(where: { Self.entryReferencesAdrafinil($0) }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
    }

    /// Removes every Adrafinil-tagged entry from one event's array, leaving the user's own hooks
    /// untouched. Shared by uninstall and install's obsolete-event cleanup.
    private func stripAdrafinil(from hooks: inout [String: Any], event: String) {
        guard var arr = hooks[event] as? [[String: Any]] else { return }
        arr = arr.filter { !Self.entryReferencesAdrafinil($0) }
        // Drop the event key once empty so uninstall leaves no `"<event>": []` residue.
        if arr.isEmpty { hooks[event] = nil } else { hooks[event] = arr }
    }

    private static func entryReferencesAdrafinil(_ entry: [String: Any]) -> Bool {
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["_adrafinil"] as? Bool) == true || ($0["command"] as? String)?.contains("adrafinil") == true }
        }
        if let cmd = entry["command"] as? String, cmd.contains("adrafinil") { return true }
        return false
    }

    private static func command(in arr: [[String: Any]]) -> String? {
        for entry in arr {
            if let inner = entry["hooks"] as? [[String: Any]],
               let cmd = inner.first(where: { ($0["_adrafinil"] as? Bool) == true || ($0["command"] as? String)?.contains("adrafinil") == true })?["command"] as? String {
                return cmd
            }
        }
        return nil
    }
}
