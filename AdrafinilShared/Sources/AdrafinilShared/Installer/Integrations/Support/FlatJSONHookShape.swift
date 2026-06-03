import Foundation

/// A flatter hook shape than `NestedJSONHookShape`: each event maps to an array of
/// `{"command": …, "_adrafinil": true}` objects directly, with no inner `hooks` wrapper.
///
/// ```json
/// { "hooks": { "sessionStart": [ { "command": "adrafinil acquire …", "_adrafinil": true } ] } }
/// ```
///
/// Used by Cursor (`sessionStart`/`sessionEnd`). The integration supplies the `(event, command)`
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
        let before = ConfigFileIO.readJSON(configPath) ?? [:]
        var after = ConfigFileIO.readJSON(configPath) ?? baseDocument
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        for entry in entries {
            merge(into: &hooks, event: entry.event, command: entry.command)
        }
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath)
        }
        return HookInstaller.InstallResult(summary: installSummary, diff: diff)
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = ConfigFileIO.readJSON(configPath), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        for entry in entries {
            if var arr = hooks[entry.event] as? [[String: Any]] {
                arr = arr.filter { ($0["command"] as? String)?.contains("adrafinil") != true }
                hooks[entry.event] = arr
            }
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath) }
        return HookInstaller.InstallResult(summary: uninstallSummary, diff: diff)
    }

    func installState() -> HookInstallState {
        guard let dict = ConfigFileIO.readJSON(configPath),
              let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }
        for entry in entries {
            guard let arr = hooks[entry.event] as? [[String: Any]],
                  let installed = Self.command(in: arr) else { return .notInstalled }
            if installed != entry.command { return .modifiedExternally }
        }
        return .installed
    }

    private func merge(into hooks: inout [String: Any], event: String, command: String) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = ["command": command, "_adrafinil": true]
        if let idx = arr.firstIndex(where: { ($0["command"] as? String)?.contains("adrafinil") == true }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
    }

    private static func command(in arr: [[String: Any]]) -> String? {
        arr.first(where: { ($0["command"] as? String)?.contains("adrafinil") == true })?["command"] as? String
    }
}
