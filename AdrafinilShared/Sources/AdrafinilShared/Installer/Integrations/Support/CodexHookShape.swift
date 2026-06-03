import Foundation

/// Codex's `hooks.json` format (verified against the Codex 0.136.0 binary): each event maps to a
/// flat array of `HookHandlerConfig` objects — for a command hook, `{ "type": "command", "command":
/// … }` directly. This is **not** Claude Code's double-nested shape (`[{ "hooks": [{ "type":
/// "command", "command": … }] }]`); Codex flattened it (a `matcher`, when present, sits on the
/// handler itself).
///
/// ```json
/// { "hooks": { "SessionStart": [ { "type": "command", "command": "adrafinil acquire …" } ] } }
/// ```
///
/// Two Codex-specific constraints shape this type:
///
/// 1. **No marker key.** Codex deserializes hooks with strict, internally-tagged enums, so an extra
///    `_adrafinil` field risks an "unexpected map key" rejection. We identify our own entry by its
///    `command` containing `adrafinil` instead of tagging it.
/// 2. **Preserve trust.** When the user trusts our hook via `/hooks`, Codex stamps a `trusted_hash`
///    onto the entry. Re-installing must therefore *leave an already-correct entry untouched* rather
///    than overwrite it — replacing it would drop the hash and force the user to re-approve. We only
///    rewrite an entry whose command drifted (e.g. the CLI path changed), and append when absent.
struct CodexHookShape {
    let configPath: String
    let event: String
    let command: String

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let before = ConfigFileIO.readJSON(configPath) ?? [:]
        var after = before
        var hooks = (after["hooks"] as? [String: Any]) ?? [:]
        var arr = (hooks[event] as? [[String: Any]]) ?? []

        if let idx = arr.firstIndex(where: { Self.isOurs($0) }) {
            // Leave a correct entry as-is so a user-applied `trusted_hash` survives; only repair a
            // drifted command (preserving any sibling keys Codex added).
            if (arr[idx]["command"] as? String) != command {
                var repaired = arr[idx]
                repaired["type"] = "command"
                repaired["command"] = command
                arr[idx] = repaired
            }
        } else {
            arr.append(["type": "command", "command": command])
        }
        hooks[event] = arr
        after["hooks"] = hooks

        let diff = ConfigFileIO.makeDiff(before: before, after: after)
        if !dryRun {
            try ConfigFileIO.ensureParentDir(of: configPath)
            try ConfigFileIO.writeJSON(after, to: configPath)
        }
        return HookInstaller.InstallResult(
            summary: "wired \(event) hook (release via process-exit watcher); trust it in Codex with /hooks",
            diff: diff,
        )
    }

    func uninstall(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = ConfigFileIO.readJSON(configPath), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        if var arr = hooks[event] as? [[String: Any]] {
            arr.removeAll { Self.isOurs($0) }
            hooks[event] = arr
        }
        dict["hooks"] = hooks
        let diff = ConfigFileIO.makeDiff(before: before, after: dict)
        if !dryRun { try ConfigFileIO.writeJSON(dict, to: configPath) }
        return HookInstaller.InstallResult(summary: "removed Codex hook entry", diff: diff)
    }

    func installState() -> HookInstallState {
        guard let dict = ConfigFileIO.readJSON(configPath),
              let hooks = dict["hooks"] as? [String: Any],
              let arr = hooks[event] as? [[String: Any]],
              let ours = arr.first(where: { Self.isOurs($0) }) else { return .notInstalled }
        // Trust (`trusted_hash`) is the user's step via `/hooks`, not something we can apply, so a
        // present-and-correct entry reads as installed regardless of trust state.
        return (ours["command"] as? String) == command ? .installed : .modifiedExternally
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("adrafinil") == true
    }
}
