import Foundation

/// Per-agent integration shape — where to write, what to write, how to detect.
///
/// The tier-1 tools (Claude Code, Codex, Cursor, Gemini CLI) share the same conceptual model: a
/// single JSON file with a `hooks` dict keyed by event name, each value an array of hook entries.
/// The shapes differ in nesting and event names. Their session id comes from the hook's stdin
/// `session_id` (read by `CLIStdin`); only Claude Code also exposes an env var.
///
/// Tier-2 tools (Crush limited hooks, Aider/Cline shell wrappers, Hermes Python plugin,
/// OpenCode and Pi TS plugins) each get a bespoke install path.
struct HookSpec {
    let agent: AgentKind
    let cliPath: String
    let homeRoot: String

    /// Whether the agent appears installed on this system. Heuristic — checks for the
    /// config dir or the binary on PATH.
    func isDetected() -> Bool {
        let fm = FileManager.default
        switch agent {
        case .claudeCode: return fm.fileExists(atPath: "\(homeRoot)/.claude")
        case .codex:      return fm.fileExists(atPath: "\(homeRoot)/.codex")
        case .cursor:     return fm.fileExists(atPath: "\(homeRoot)/.cursor") ||
                                  fm.fileExists(atPath: "/Applications/Cursor.app")
        case .geminiCLI:  return fm.fileExists(atPath: "\(homeRoot)/.gemini")
        case .crush:      return binaryOnPath("crush")
        case .aider:      return binaryOnPath("aider")
        case .hermes:     return fm.fileExists(atPath: "\(homeRoot)/.hermes")
        case .openCode:   return binaryOnPath("opencode")
        case .cline:      return binaryOnPath("cline")
        case .pi:         return fm.fileExists(atPath: "\(homeRoot)/.pi")
        }
    }

    func install(dryRun: Bool) throws -> HookInstaller.InstallResult {
        switch agent {
        case .claudeCode: return try installSharedJSONShape(.claudeCode, dryRun: dryRun)
        case .codex:      return try installSharedJSONShape(.codex, dryRun: dryRun)
        case .cursor:     return try installCursorShape(dryRun: dryRun)
        case .geminiCLI:  return try installSharedJSONShape(.geminiCLI, dryRun: dryRun)

        case .crush:
            return try installCrushShape(dryRun: dryRun)
        case .aider, .cline:
            return try installShellWrapper(dryRun: dryRun)
        case .hermes:
            return try installHermesPlugin(dryRun: dryRun)
        case .openCode:
            return try installOpenCodePlugin(dryRun: dryRun)
        case .pi:
            return try installPiPlugin(dryRun: dryRun)
        }
    }

    /// Removes Adrafinil entries for this agent. When `dryRun` is `true`, returns a diff of
    /// what would change without writing anything to disk.
    @discardableResult
    func uninstall(dryRun: Bool = false) throws -> HookInstaller.InstallResult {
        switch agent {
        case .claudeCode, .codex, .geminiCLI:
            return try removeFromSharedJSONShape(agent, dryRun: dryRun)
        case .cursor:
            return try removeFromCursor(dryRun: dryRun)
        case .hermes:
            return try removePluginFolder(dryRun: dryRun)
        case .openCode, .pi:
            return try removePluginFile(dryRun: dryRun)
        case .crush:
            return try removeFromCrushShape(dryRun: dryRun)
        case .aider, .cline:
            return try removeShellWrapper(dryRun: dryRun)
        }
    }

    /// Returns the hook-installation state for this agent (SPEC §7.2).
    func installState() -> HookInstallState {
        switch agent {
        case .claudeCode, .codex, .geminiCLI:
            return installStateForSharedJSONShape()
        case .cursor:
            return installStateForCursor()
        case .hermes:
            return installStateForFilePlugin(configPath)
        case .openCode, .pi:
            return installStateForFilePlugin(configPath)
        case .crush:
            return installStateForCrushShape()
        case .aider, .cline:
            return installStateForShellWrapper()
        }
    }

    // MARK: - Paths

    private var configPath: String {
        switch agent {
        case .claudeCode: return "\(homeRoot)/.claude/settings.json"
        case .codex:      return "\(homeRoot)/.codex/hooks.json"
        case .cursor:     return "\(homeRoot)/.cursor/hooks.json"
        case .geminiCLI:  return "\(homeRoot)/.gemini/settings.json"
        case .crush:      return "\(homeRoot)/.config/crush/crush.json"
        case .hermes:     return "\(pluginRoot)/__init__.py"
        case .openCode:   return "\(homeRoot)/.config/opencode/plugins/adrafinil.ts"
        case .pi:         return "\(pluginRoot)/adrafinil.ts"
        case .aider, .cline:
            return "\(homeRoot)/.zshrc"
        }
    }

    private var pluginRoot: String {
        switch agent {
        case .hermes: return "\(homeRoot)/.hermes/plugins/adrafinil"
        case .openCode: return "\(homeRoot)/.config/opencode/plugins"
        case .pi: return "\(homeRoot)/.pi/agent/extensions"
        default: return ""
        }
    }

    // MARK: - Shared JSON shape (Claude Code, Codex, Gemini CLI)

    private enum JSONShape {
        case claudeCode, codex, geminiCLI
        var startEvent: String {
            switch self {
            case .claudeCode: "SessionStart"
            case .codex:      "SessionStart"
            case .geminiCLI:  "SessionStart"
            }
        }
        /// Release-hook event, or nil to release via the process-exit watcher instead.
        var endEvent: String? {
            switch self {
            case .claudeCode: "SessionEnd"
            // Codex's `Stop` fires per *turn*, not at session end, so a Stop→release would drop
            // the assertion after the first turn while the session keeps working. Codex exposes
            // no session-end hook, so we acquire on SessionStart and release via the daemon's
            // process-exit watcher when the `codex` process exits (SPEC §5.5).
            case .codex:      nil
            case .geminiCLI:  "SessionEnd"
            }
        }
    }

    private func installSharedJSONShape(_ shape: JSONShape, dryRun: Bool) throws -> HookInstaller.InstallResult {
        let dict = readJSON() ?? [:]
        let toolID = agent.rawValue
        let sessionVar = sessionEnvVar(for: agent)

        let acquireCmd = hookCommand("acquire", tool: toolID, sessionVar: sessionVar)
        let releaseCmd = hookCommand("release", tool: toolID, sessionVar: sessionVar)
        let endEvent = shape.endEvent

        let entry: ([String: Any]) -> [String: Any] = { existing in
            var out = existing
            var hooksDict = (out["hooks"] as? [String: Any]) ?? [:]
            mergeHookList(into: &hooksDict, event: shape.startEvent, command: acquireCmd)
            if let endEvent { mergeHookList(into: &hooksDict, event: endEvent, command: releaseCmd) }
            out["hooks"] = hooksDict
            return out
        }

        let new = entry(dict)
        let diff = makeDiff(before: dict, after: new)
        if !dryRun {
            try ensureParentDir()
            try writeJSON(new)
        }
        let summary = endEvent.map { "wired SessionStart/\($0) hooks" }
            ?? "wired SessionStart hook (release via process-exit watcher; trust it in Codex with /hooks)"
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    private func removeFromSharedJSONShape(_ agent: AgentKind, dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = readJSON(), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        for event in ["SessionStart", "SessionEnd", "Stop"] {
            if var arr = hooks[event] as? [[String: Any]] {
                arr = arr.filter { !entryReferencesAdrafinil($0) }
                hooks[event] = arr
            }
        }
        dict["hooks"] = hooks
        let diff = makeDiff(before: before, after: dict)
        if !dryRun { try writeJSON(dict) }
        return HookInstaller.InstallResult(summary: "removed hook entries", diff: diff)
    }

    // Insert (or repair) our entry under `event`. Self-healing and idempotent: if an
    // Adrafinil-tagged entry already exists we *replace* it with the canonical form, so
    // re-running install upgrades a stale command (e.g. an old session-id variable) instead
    // of leaving the broken one in place. A non-Adrafinil entry is never touched.
    private func mergeHookList(into hooks: inout [String: Any], event: String, command: String) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = [
            "hooks": [
                ["type": "command", "command": command, "_adrafinil": true]
            ]
        ]
        if let idx = arr.firstIndex(where: { entryReferencesAdrafinil($0) }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
    }

    private func entryReferencesAdrafinil(_ entry: [String: Any]) -> Bool {
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["_adrafinil"] as? Bool) == true || ($0["command"] as? String)?.contains("adrafinil") == true }
        }
        if let cmd = entry["command"] as? String, cmd.contains("adrafinil") { return true }
        return false
    }

    // MARK: - Cursor (flat shape, no nested "hooks": [{"hooks": [...]}])

    private func installCursorShape(dryRun: Bool) throws -> HookInstaller.InstallResult {
        var dict = readJSON() ?? ["version": 1]
        var hooks = (dict["hooks"] as? [String: Any]) ?? [:]
        // No CURSOR_SESSION_ID env var exists — Cursor passes session_id on stdin (CLIStdin reads it).
        let acquire = hookCommand("acquire", tool: "cursor", sessionVar: nil)
        let release = hookCommand("release", tool: "cursor", sessionVar: nil)
        mergeFlatHook(into: &hooks, event: "sessionStart", command: acquire)
        mergeFlatHook(into: &hooks, event: "sessionEnd", command: release)
        dict["hooks"] = hooks
        let diff = makeDiff(before: readJSON() ?? [:], after: dict)
        if !dryRun {
            try ensureParentDir()
            try writeJSON(dict)
        }
        return HookInstaller.InstallResult(summary: "wired sessionStart/sessionEnd hooks", diff: diff)
    }

    private func removeFromCursor(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = readJSON(), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        for event in ["sessionStart", "sessionEnd"] {
            if var arr = hooks[event] as? [[String: Any]] {
                arr = arr.filter { ($0["command"] as? String)?.contains("adrafinil") != true }
                hooks[event] = arr
            }
        }
        dict["hooks"] = hooks
        let diff = makeDiff(before: before, after: dict)
        if !dryRun { try writeJSON(dict) }
        return HookInstaller.InstallResult(summary: "removed Cursor hook entries", diff: diff)
    }

    private func mergeFlatHook(into hooks: inout [String: Any], event: String, command: String) {
        var arr = (hooks[event] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = ["command": command, "_adrafinil": true]
        if let idx = arr.firstIndex(where: { ($0["command"] as? String)?.contains("adrafinil") == true }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks[event] = arr
    }

    // MARK: - Crush (PreToolUse only)

    private func installCrushShape(dryRun: Bool) throws -> HookInstaller.InstallResult {
        var dict = readJSON() ?? [:]
        var hooks = (dict["hooks"] as? [String: Any]) ?? [:]
        var arr = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        let canonical: [String: Any] = ["command": "\(quotedCLI) acquire $CRUSH_SESSION_ID --tool crush", "_adrafinil": true]
        if let idx = arr.firstIndex(where: { ($0["command"] as? String)?.contains("adrafinil") == true }) {
            arr[idx] = canonical
        } else {
            arr.append(canonical)
        }
        hooks["PreToolUse"] = arr
        dict["hooks"] = hooks
        let diff = makeDiff(before: readJSON() ?? [:], after: dict)
        if !dryRun {
            try ensureParentDir()
            try writeJSON(dict)
        }
        return HookInstaller.InstallResult(summary: "wired PreToolUse hook (release via process-exit watcher)", diff: diff)
    }

    private func removePluginFolder(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let root = pluginRoot
        let exists = FileManager.default.fileExists(atPath: root)
        if !exists {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        if !dryRun {
            try FileManager.default.removeItem(atPath: root)
        }
        return HookInstaller.InstallResult(summary: "removed plugin folder", diff: "- \(root)")
    }

    /// Removes only our single plugin file (not the shared extensions/plugins directory, which may
    /// hold the user's other plugins). Used for OpenCode and Pi.
    private func removePluginFile(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path) else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        if !dryRun {
            try FileManager.default.removeItem(atPath: path)
        }
        return HookInstaller.InstallResult(summary: "removed plugin file", diff: "- \(path)")
    }

    private func removeFromCrushShape(dryRun: Bool) throws -> HookInstaller.InstallResult {
        guard var dict = readJSON(), var hooks = dict["hooks"] as? [String: Any] else {
            return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)")
        }
        let before = dict
        if var arr = hooks["PreToolUse"] as? [[String: Any]] {
            arr = arr.filter { ($0["command"] as? String)?.contains("adrafinil") != true }
            hooks["PreToolUse"] = arr
        }
        dict["hooks"] = hooks
        let diff = makeDiff(before: before, after: dict)
        if !dryRun { try writeJSON(dict) }
        return HookInstaller.InstallResult(summary: "removed Crush hook entry", diff: diff)
    }

    // MARK: - Aider/Cline shell wrapper

    /// Path for the standalone wrapper script, e.g. `~/.local/bin/aider-adrafinil`.
    private var wrapperScriptPath: String {
        "\(homeRoot)/.local/bin/\(agent.rawValue)-adrafinil"
    }

    /// Shell rc files that receive the alias. Both zsh and bash are written so the
    /// alias is available regardless of which shell the user runs inside their terminal.
    private var shellRCPaths: [String] {
        ["\(homeRoot)/.zshrc", "\(homeRoot)/.bashrc"]
    }

    private func installShellWrapper(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let scriptPath = wrapperScriptPath
        // The wrapper script: acquire → run the real tool → release.
        let script = """
        #!/usr/bin/env bash
        \(quotedCLI) acquire $$ --tool \(agent.rawValue)
        \(agent.rawValue) "$@"
        status=$?
        \(quotedCLI) release $$
        exit $status
        """

        // Alias that replaces the plain `aider`/`cline` command with our wrapper.
        let marker = "# adrafinil-\(agent.rawValue)"
        let alias  = "alias \(agent.rawValue)='\(scriptPath)'"
        let block  = "\(marker)\n\(alias)\n# end-adrafinil-\(agent.rawValue)"

        var diff = ""
        var changed = false

        for rcPath in shellRCPaths {
            var current = (try? String(contentsOfFile: rcPath, encoding: .utf8)) ?? ""
            if current.contains(marker) { continue }
            current += "\n" + block + "\n"
            if !dryRun { try current.write(toFile: rcPath, atomically: true, encoding: .utf8) }
            diff += "+ \(rcPath): \(alias)\n"
            changed = true
        }

        // Write the wrapper script itself.
        let scriptExists = FileManager.default.fileExists(atPath: scriptPath)
        if !scriptExists {
            diff += "+ \(scriptPath) (wrapper script)\n"
            if !dryRun {
                let dir = (scriptPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                chmod(scriptPath, 0o755)
            }
            changed = true
        }

        if !changed { return HookInstaller.InstallResult(summary: "already installed", diff: "(unchanged)") }
        return HookInstaller.InstallResult(summary: "installed \(agent.rawValue)-adrafinil wrapper + alias", diff: diff)
    }

    private func removeShellWrapper(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let marker    = "# adrafinil-\(agent.rawValue)"
        let endMarker = "# end-adrafinil-\(agent.rawValue)"
        var diff = ""

        for rcPath in shellRCPaths {
            guard let current = try? String(contentsOfFile: rcPath, encoding: .utf8) else { continue }
            let lines = current.components(separatedBy: "\n")
            var out: [String] = []
            var inBlock = false
            for line in lines {
                if line.hasPrefix(marker)    { inBlock = true; continue }
                if line.hasPrefix(endMarker) { inBlock = false; continue }
                if inBlock { continue }
                // Legacy single-line marker support (no end marker).
                if line.hasPrefix("# adrafinil-") && line.contains(agent.rawValue) { continue }
                out.append(line)
            }
            let updated = out.joined(separator: "\n")
            if updated != current {
                diff += "- \(rcPath): removed alias block\n"
                if !dryRun { try updated.write(toFile: rcPath, atomically: true, encoding: .utf8) }
            }
        }

        let scriptPath = wrapperScriptPath
        if FileManager.default.fileExists(atPath: scriptPath) {
            diff += "- \(scriptPath)\n"
            if !dryRun { try? FileManager.default.removeItem(atPath: scriptPath) }
        }

        if diff.isEmpty { return HookInstaller.InstallResult(summary: "nothing to remove", diff: "(unchanged)") }
        return HookInstaller.InstallResult(summary: "removed \(agent.rawValue) wrapper + alias", diff: diff)
    }

    // MARK: - Hermes Python plugin

    /// Canonical Hermes `__init__.py`. Hermes delivers the session id as a callback **kwarg**
    /// (`session_id`), not a shell env var — `${HERMES_SESSION_ID}` would be a literal string
    /// inside a Python lambda. The plugin entry point must be named `__init__.py`.
    private func hermesInitPy() -> String {
        """
        import subprocess

        CLI = \(swiftStringLiteral: cliPath)

        def _acquire(session_id=None, **kwargs):
            if session_id:
                subprocess.run([CLI, "acquire", session_id, "--tool", "hermes"])

        def _release(session_id=None, **kwargs):
            if session_id:
                subprocess.run([CLI, "release", session_id, "--tool", "hermes"])

        def register(ctx):
            ctx.register_hook("on_session_start", _acquire)
            ctx.register_hook("on_session_end", _release)
        """
    }

    /// Mandatory Hermes plugin manifest (declares the hooks it provides).
    private func hermesPluginYaml() -> String {
        """
        name: adrafinil
        version: 1.0.0
        description: Adrafinil sleep-prevention session hooks
        provides_hooks:
          - on_session_start
          - on_session_end
        """
    }

    private func installHermesPlugin(dryRun: Bool) throws -> HookInstaller.InstallResult {
        let manifestPath = "\(pluginRoot)/plugin.yaml"
        var diff = "+ \(configPath)\n+ \(manifestPath)"
        if !dryRun {
            try FileManager.default.createDirectory(atPath: pluginRoot, withIntermediateDirectories: true)
            try hermesInitPy().write(toFile: configPath, atomically: true, encoding: .utf8)
            try hermesPluginYaml().write(toFile: manifestPath, atomically: true, encoding: .utf8)
        }
        // Hermes plugins are opt-in: they only load when enabled in ~/.hermes/config.yaml. Append a
        // minimal enable block when there's no existing `plugins:` section (a naive merge into an
        // existing one risks duplicate YAML keys); otherwise surface the manual step.
        let configYaml = "\(homeRoot)/.hermes/config.yaml"
        let existing = (try? String(contentsOfFile: configYaml, encoding: .utf8)) ?? ""
        var summary = "wrote Hermes plugin (plugin.yaml + __init__.py)"
        if existing.contains("adrafinil") {
            // already referenced — assume enabled
        } else if !existing.contains("plugins:") {
            let block = "\nplugins:\n  enabled:\n    - adrafinil\n"
            if !dryRun { try (existing + block).write(toFile: configYaml, atomically: true, encoding: .utf8) }
            diff += "\n~ \(configYaml): enable adrafinil"
        } else {
            summary += " — run `hermes plugins enable adrafinil` to activate"
        }
        return HookInstaller.InstallResult(summary: summary, diff: diff)
    }

    // MARK: - OpenCode TS plugin

    private func installOpenCodePlugin(dryRun: Bool) throws -> HookInstaller.InstallResult {
        if !dryRun {
            try FileManager.default.createDirectory(atPath: pluginRoot, withIntermediateDirectories: true)
            try openCodePluginTS().write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        return HookInstaller.InstallResult(summary: "wrote OpenCode plugin", diff: "+ \(configPath)")
    }

    /// Canonical OpenCode plugin. Acquire on `session.created` only — `session.idle` fires per-turn
    /// (every time the agent finishes responding, not at session end), so releasing on it would
    /// drop the assertion mid-session (the same trap as Codex's per-turn `Stop`). Release instead
    /// rides the daemon's process-exit watcher when the `opencode` process exits (SPEC §5.5). The
    /// session id is `event.properties.info.id` for `session.created` (the `Session` object).
    private func openCodePluginTS() -> String {
        """
        export const Adrafinil = async ({ $ }) => {
          return {
            event: async ({ event }) => {
              if (event.type === "session.created") await $`\(cliPath) acquire ${event.properties.info.id} --tool opencode`
            }
          }
        }
        """
    }

    // MARK: - Pi TS extension

    private func installPiPlugin(dryRun: Bool) throws -> HookInstaller.InstallResult {
        if !dryRun {
            try FileManager.default.createDirectory(atPath: pluginRoot, withIntermediateDirectories: true)
            try piExtensionTS().write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        return HookInstaller.InstallResult(summary: "wrote Pi extension", diff: "+ \(configPath)")
    }

    /// Canonical Pi extension (`~/.pi/agent/extensions/adrafinil.ts`). Pi auto-discovers `.ts`
    /// extensions and calls `pi.on(<event>, handler)` from the default export. `session_start`
    /// acquires; `session_shutdown` (fired on process exit) releases. Pi has no session-id env var
    /// or stdin payload — the id is the session file path (`undefined` for ephemeral sessions, so
    /// fall back to the pid). Shelling out via `node:child_process`, mirroring the OpenCode plugin.
    private func piExtensionTS() -> String {
        """
        import { execFileSync } from "node:child_process"

        function run(args) {
          try { execFileSync(\(swiftStringLiteral: cliPath), args) } catch (_) {}
        }

        export default function (pi) {
          const id = (ctx) => ctx?.sessionManager?.getSessionFile?.() ?? String(process.pid)
          pi.on("session_start", async (_event, ctx) => run(["acquire", id(ctx), "--tool", "pi"]))
          pi.on("session_shutdown", async (_event, ctx) => run(["release", id(ctx), "--tool", "pi"]))
        }
        """
    }

    // MARK: - Install-state inspection (SPEC §7.2)

    private func installStateForSharedJSONShape() -> HookInstallState {
        guard let dict = readJSON(),
              let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }

        let toolID = agent.rawValue
        let sessionVar = sessionEnvVar(for: agent)
        let acquireCmd = hookCommand("acquire", tool: toolID, sessionVar: sessionVar)
        let releaseCmd = hookCommand("release", tool: toolID, sessionVar: sessionVar)

        // Codex installs only a SessionStart hook (release is via the process-exit watcher, §5.5).
        let startEvent = "SessionStart"
        let endEvent: String? = agent == .codex ? nil : "SessionEnd"

        func commandInArray(_ arr: [[String: Any]]) -> String? {
            for entry in arr {
                if let inner = entry["hooks"] as? [[String: Any]] {
                    if let cmd = inner.first(where: { ($0["_adrafinil"] as? Bool) == true || ($0["command"] as? String)?.contains("adrafinil") == true })?["command"] as? String {
                        return cmd
                    }
                }
            }
            return nil
        }

        guard let startArr = hooks[startEvent] as? [[String: Any]],
              let installedAcquire = commandInArray(startArr) else { return .notInstalled }

        guard let endEvent else {
            return installedAcquire == acquireCmd ? .installed : .modifiedExternally
        }

        guard let endArr = hooks[endEvent] as? [[String: Any]],
              let installedRelease = commandInArray(endArr) else { return .notInstalled }

        let matches = installedAcquire == acquireCmd && installedRelease == releaseCmd
        return matches ? .installed : .modifiedExternally
    }

    private func installStateForCursor() -> HookInstallState {
        guard let dict = readJSON(),
              let hooks = dict["hooks"] as? [String: Any] else { return .notInstalled }
        let expectedAcquire = hookCommand("acquire", tool: "cursor", sessionVar: nil)
        let expectedRelease = hookCommand("release", tool: "cursor", sessionVar: nil)

        func adrafinilCommand(in arr: [[String: Any]]) -> String? {
            arr.first(where: { ($0["command"] as? String)?.contains("adrafinil") == true })?["command"] as? String
        }

        guard let startArr = hooks["sessionStart"] as? [[String: Any]],
              let endArr   = hooks["sessionEnd"]   as? [[String: Any]],
              let installedAcquire = adrafinilCommand(in: startArr),
              let installedRelease = adrafinilCommand(in: endArr) else { return .notInstalled }

        return (installedAcquire == expectedAcquire && installedRelease == expectedRelease) ? .installed : .modifiedExternally
    }

    private func installStateForFilePlugin(_ path: String) -> HookInstallState {
        guard FileManager.default.fileExists(atPath: path),
              let actual = try? String(contentsOfFile: path, encoding: .utf8),
              actual.contains("adrafinil") else { return .notInstalled }
        // Compare the on-disk content to the canonical content we'd generate (reusing the same
        // generators the installer writes, so the two never drift).
        let canonical: String?
        switch agent {
        case .hermes:   canonical = hermesInitPy()
        case .openCode: canonical = openCodePluginTS()
        case .pi:       canonical = piExtensionTS()
        default:        return .installed
        }
        guard let expected = canonical else { return .modifiedExternally }
        return actual.trimmingCharacters(in: .whitespacesAndNewlines) ==
               expected.trimmingCharacters(in: .whitespacesAndNewlines)
               ? .installed : .modifiedExternally
    }

    private func installStateForCrushShape() -> HookInstallState {
        guard let dict = readJSON(),
              let hooks = dict["hooks"] as? [String: Any],
              let arr = hooks["PreToolUse"] as? [[String: Any]] else { return .notInstalled }
        let expectedCmd = "\(quotedCLI) acquire $CRUSH_SESSION_ID --tool crush"
        guard let installedCmd = arr.first(where: { ($0["command"] as? String)?.contains("adrafinil") == true })?["command"] as? String else {
            return .notInstalled
        }
        return installedCmd == expectedCmd ? .installed : .modifiedExternally
    }

    private func installStateForShellWrapper() -> HookInstallState {
        let marker = "# adrafinil-\(agent.rawValue)"
        let scriptExists = FileManager.default.fileExists(atPath: wrapperScriptPath)
        // Check if the marker appears in any rc file.
        let markerInAnyRC = shellRCPaths.contains { path in
            (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) ?? false
        }
        guard markerInAnyRC || scriptExists else { return .notInstalled }
        // Both rc files should have the marker and the script should exist.
        let allRCsHaveMarker = shellRCPaths.allSatisfy { path in
            (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) ?? false
        }
        guard allRCsHaveMarker && scriptExists else { return .modifiedExternally }
        // Check the alias in rc files points to the correct wrapper path.
        let expectedAlias = "alias \(agent.rawValue)='\(wrapperScriptPath)'"
        let aliasCorrect = shellRCPaths.allSatisfy { path in
            (try? String(contentsOfFile: path, encoding: .utf8))?.contains(expectedAlias) ?? false
        }
        return aliasCorrect ? .installed : .modifiedExternally
    }

    // MARK: - JSON I/O

    private func readJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func writeJSON(_ dict: [String: Any], toPath path: String? = nil) throws {
        let target = path ?? configPath
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
    }

    private func ensureParentDir() throws {
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func makeDiff(before: [String: Any], after: [String: Any]) -> String {
        let beforeData = (try? JSONSerialization.data(withJSONObject: before, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let afterData = (try? JSONSerialization.data(withJSONObject: after, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let beforeStr = String(data: beforeData, encoding: .utf8) ?? ""
        let afterStr = String(data: afterData, encoding: .utf8) ?? ""
        if beforeStr == afterStr { return "(unchanged)" }
        return "BEFORE:\n\(beforeStr)\n---\nAFTER:\n\(afterStr)"
    }

    /// The shell env var carrying the session id in the hook command, or nil when the agent exposes
    /// none (the CLI then reads `session_id` from the hook's stdin JSON — `CLIStdin`).
    ///
    /// Only Claude Code exposes a real env var (`CLAUDE_CODE_SESSION_ID`, verified against 2.1.158;
    /// *not* `CLAUDE_SESSION_ID`, which expands empty). Codex, Cursor, and Gemini CLI deliver the id
    /// **only** on stdin — there is no `CODEX_THREAD_ID`/`CURSOR_SESSION_ID`/`GEMINI_SESSION_ID` hook
    /// env var, so embedding one is dead weight (it expands empty and the stdin reader wins anyway).
    private func sessionEnvVar(for agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: "$CLAUDE_CODE_SESSION_ID"
        default:          nil
        }
    }

    /// Builds an `acquire`/`release` hook command. When `sessionVar` is nil the positional key is
    /// omitted entirely and the CLI sources the session id from stdin (`session_id`).
    private func hookCommand(_ op: String, tool: String, sessionVar: String?) -> String {
        if let sessionVar {
            return "\(quotedCLI) \(op) \(sessionVar) --tool \(tool)"
        }
        return "\(quotedCLI) \(op) --tool \(tool)"
    }

    private var quotedCLI: String {
        // Quote the CLI path in case it contains spaces (it lives inside the .app bundle).
        cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath
    }

    static func `for`(agent: AgentKind, cliPath: String, homeRoot: String = NSHomeDirectory()) -> HookSpec {
        HookSpec(agent: agent, cliPath: cliPath, homeRoot: homeRoot)
    }
}

private extension DefaultStringInterpolation {
    mutating func appendInterpolation(swiftStringLiteral item: String) {
        appendInterpolation("\"\(item)\"")
    }
}
