import Foundation

/// Best-effort verification that the user has *trusted* Adrafinil's Codex hooks.
///
/// Codex won't run a command hook until it's trusted: the user approves it in the TUI via `/hooks`,
/// and Codex records the approval in `~/.codex/config.toml` as a table
/// `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]` carrying a `trusted_hash` (event
/// labels are snake_case there — `user_prompt_submit`, `stop` — even though the `hooks.json` keys are
/// CamelCase). We detect that a `trusted_hash` is recorded for our handlers rather than recomputing
/// Codex's hash: the hash is taken over Codex's *internal* normalized handler identity, so reproducing
/// it would couple us to Codex internals and break on an upgrade. Since the installer keeps our command
/// byte-stable — which is exactly what keeps an existing `trusted_hash` valid — a recorded hash on our
/// key is a reliable "trusted" signal.
///
/// This is guidance, never a gate. A false `untrusted` just re-shows the instructions; a false
/// `trusted` at worst lets a still-untrusted hook fail quietly until the user sees Codex prompt them.
/// Returns `.unknown` when `hooks.json` isn't installed or `config.toml` is absent/unreadable.
public enum CodexHookTrust {
    public enum Status: String, Sendable, Equatable {
        /// Every managed hook event has a recorded `trusted_hash`.
        case trusted
        /// Some, but not all, managed events are trusted (e.g. the user approved the acquire hook but
        /// not the newly-added `Stop` release).
        case partiallyTrusted
        /// No managed event has a recorded `trusted_hash`.
        case untrusted
        /// `hooks.json` isn't installed, or `config.toml` couldn't be read — trust is indeterminate.
        case unknown
    }

    /// Event labels exactly as Codex keys them in `config.toml` (snake_case), for the events the Codex
    /// integration wires. Keep in sync with `CodexIntegration`'s acquire/release events.
    static let managedEventLabels = ["user_prompt_submit", "stop"]

    /// Trust status for the Codex hooks under `homeRoot` (production passes `NSHomeDirectory()`).
    public static func status(homeRoot: String) -> Status {
        let hooksPath = "\(homeRoot)/.codex/hooks.json"
        guard FileManager.default.fileExists(atPath: hooksPath) else { return .unknown }
        guard let toml = try? String(contentsOfFile: "\(homeRoot)/.codex/config.toml", encoding: .utf8) else {
            return .unknown
        }
        let trustedCount = managedEventLabels.count { label in
            hasTrustedHash(in: toml, hooksPath: hooksPath, eventLabel: label)
        }
        if trustedCount == 0 { return .untrusted }
        if trustedCount == managedEventLabels.count { return .trusted }
        return .partiallyTrusted
    }

    /// Whether `config.toml` records a non-empty `trusted_hash` for a `[hooks.state."…"]` table whose
    /// key names our `hooks.json` path and the given snake_case event label. Tolerant of key ordering
    /// and toml_edit's standard table-header formatting (`[projects."…"]`-style quoted dotted keys).
    static func hasTrustedHash(in toml: String, hooksPath: String, eventLabel: String) -> Bool {
        let lines = toml.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard isHooksStateHeader(lines[index], hooksPath: hooksPath, eventLabel: eventLabel) else { continue }
            // Scan the table body up to the next header for a non-empty trusted_hash.
            var body = index + 1
            while body < lines.count {
                let line = lines[body].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if let value = trustedHashValue(in: line), !value.isEmpty { return true }
                body += 1
            }
        }
        return false
    }

    private static func isHooksStateHeader(_ rawLine: String, hooksPath: String, eventLabel: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("[hooks.state."), line.hasSuffix("]") else { return false }
        // The whole `<path>:<event>:<group>:<handler>` key is one quoted segment, so both the path and
        // the `:<event>:` delimiter appear verbatim inside the header.
        return line.contains(hooksPath) && line.contains(":\(eventLabel):")
    }

    private static func trustedHashValue(in line: String) -> String? {
        guard line.hasPrefix("trusted_hash"), let eq = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
    }
}
