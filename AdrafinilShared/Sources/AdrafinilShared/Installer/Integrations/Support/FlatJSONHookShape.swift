import Foundation

/// A flatter hook shape than `NestedJSONHookShape`: each event maps to an array of
/// `{"command": …, "_adrafinil": true}` objects directly, with no inner `hooks` wrapper.
///
/// ```json
/// { "hooks": { "beforeSubmitPrompt": [ { "command": "adrafinil acquire …", "_adrafinil": true } ] } }
/// ```
///
/// Used by Cursor (`beforeSubmitPrompt`/`stop`). The integration supplies the `(event, command)`
/// pairs it manages and an optional base document (Cursor seeds `{"version": 1}` on a fresh file).
struct FlatJSONHookShape {
    let configPath: String
    /// The events and commands this integration owns, in write order.
    let entries: [(event: String, command: String)]
    /// Seed document used when the config file doesn't exist yet.
    var baseDocument: [String: Any] = [:]
    /// Human-readable summaries.
    var installSummary: String
    var uninstallSummary: String

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let existing = try ConfigFileIO.readJSONForUpdate(configPath)
        let before = existing ?? [:]
        var after = existing ?? baseDocument
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        // Canonicalize, don't just merge: strip our entries from every event first, so one left
        // under an event this build no longer uses (an older shape — e.g. Cursor's session-scoped
        // hooks, issue #15) can't survive the once-per-build reinstall and keep firing.
        Self.removeOurEntries(from: &hooks)
        for entry in entries {
            merge(into: &hooks, event: entry.event, command: entry.command)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath, replacing: existing)
        }
        return HookInstaller.InstallResult(summary: installSummary, diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard let existing = try ConfigFileIO.readJSONForUpdate(configPath),
              var hooks = existing["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        var dict = existing
        let before = dict
        Self.removeOurEntries(from: &hooks)
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath, replacing: existing) }
        return HookInstaller.InstallResult(summary: uninstallSummary, diff: diff)
    }

    func installState() -> HookInstallState {
        switch ConfigFileIO.read(configPath) {
        case .missing:
            return .notInstalled
        case .unparseable:
            return .configUnreadable
        case let .object(dict):
            guard let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }
            // Any adrafinil entry anywhere means our hooks are (partially) present; a partial set
            // must read as drifted, not `.notInstalled`, so the UI can offer to clean it up.
            let anyOurs = hooks.values.contains { value in
                guard let arr = value as? [[String: Any]] else { return false }
                return arr.contains { Self.entryIsOurs($0) }
            }
            for entry in entries {
                guard let arr = hooks[entry.event] as? [[String: Any]],
                      let installed = Self.command(in: arr) else {
                    return anyOurs ? .modifiedExternally : .notInstalled
                }
                if installed != entry.command { return .modifiedExternally }
            }
            return .installed
        }
    }

    private func merge(into hooks: inout [String: Any], event: String, command: String) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = ["command": command, "_adrafinil": true]
        if let idx = arr.firstIndex(where: { Self.entryIsOurs($0) }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
    }

    /// Strips our entries from every event — including one the user may have moved them to, or one
    /// an older build wrote — and drops emptied event arrays so no `"<event>": []` residue is left.
    private static func removeOurEntries(from hooks: inout [String: Any]) {
        for event in hooks.keys {
            guard let arr = hooks[event] as? [[String: Any]] else { continue }
            let pruned = arr.filter { !entryIsOurs($0) }
            hooks[event] = pruned.isEmpty ? nil : pruned
        }
    }

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        (entry["_adrafinil"] as? Bool) == true
            || ConfigFileIO.commandInvokesAdrafinilCLI(entry["command"] as? String)
    }

    private static func command(in arr: [[String: Any]]) -> String? {
        arr.first(where: { entryIsOurs($0) })?["command"] as? String
    }
}
