import Foundation

/// The nested hook shape shared by Claude Code, Codex, and Gemini CLI: a single JSON file with a
/// top-level `hooks` dict keyed by event name, each value an array of entries that themselves wrap
/// an inner `hooks` array of `{"type": "command", "command": …}` objects.
///
/// ```json
/// { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "adrafinil acquire …" } ] } ] } }
/// ```
///
/// Adrafinil's own entries are tagged with `_adrafinil: true` so install is self-healing (it
/// replaces a stale entry in place) and uninstall removes only ours, leaving the user's hooks intact.
struct NestedJSONHookShape {
    let configPath: String
    let startEvent: String
    /// Release-hook event, or nil to release via the daemon's process-exit watcher instead
    /// (Codex's `Stop` fires per-turn, not at session end, so it has no usable end hook).
    let endEvent: String?
    let acquireCommand: String
    let releaseCommand: String

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let before = ConfigFileIO.readJSON(configPath) ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        merge(into: &hooks, event: startEvent, command: acquireCommand)
        if let endEvent { merge(into: &hooks, event: endEvent, command: releaseCommand) }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath)
        }
        let summary = endEvent.map { "wired \(startEvent)/\($0) hooks" }
            ?? "wired \(startEvent) hook (release via process-exit watcher)"
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = ConfigFileIO.readJSON(configPath), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        // Clean our entry from this agent's events plus the legacy `Stop` event an earlier
        // version may have written.
        let events = Set([startEvent, endEvent].compactMap { $0 } + ["SessionEnd", "Stop"])
        for event in events {
            if var arr = hooks[event] as? [[String: Any]] {
                arr = arr.filter { !Self.entryReferencesAdrafinil($0) }
                hooks[event] = arr
            }
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

        guard let endEvent else {
            return installedAcquire == acquireCommand ? .installed : .modifiedExternally
        }
        guard let endArr = hooks[endEvent] as? [[String: Any]],
              let installedRelease = Self.command(in: endArr) else { return .notInstalled }

        let matches = installedAcquire == acquireCommand && installedRelease == releaseCommand
        return matches ? .installed : .modifiedExternally
    }

    // MARK: - Entry helpers

    /// Inserts (or repairs) our entry under `event`. Idempotent: if an Adrafinil-tagged entry
    /// already exists it's *replaced* with the canonical form, so re-running install upgrades a
    /// stale command instead of leaving the broken one in place. A non-Adrafinil entry is untouched.
    private func merge(into hooks: inout [String: Any], event: String, command: String) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = [
            "hooks": [["type": "command", "command": command, "_adrafinil": true]]
        ]
        if let idx = arr.firstIndex(where: { Self.entryReferencesAdrafinil($0) }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
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
