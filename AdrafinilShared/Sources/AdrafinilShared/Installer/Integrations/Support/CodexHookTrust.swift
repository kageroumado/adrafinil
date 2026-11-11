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

    /// Whether `config.toml` records a non-empty `trusted_hash` under `hooks.state."<path>:<event>:…"`
    /// for our `hooks.json` path and the given snake_case event label.
    ///
    /// Keys are compared by value, so every TOML spelling of the same key matches: bare or quoted
    /// segments (`hooks`, `"hooks"`, `'hooks'`), whitespace around dots, and a key split between a
    /// table header and a dotted key (`[hooks.state]` followed by `"<path>:…".trusted_hash = …`).
    static func hasTrustedHash(in toml: String, hooksPath: String, eventLabel: String) -> Bool {
        let handlerPrefix = "\(hooksPath):\(eventLabel):"
        // The key path of the current `[table]`; nil inside an `[[array table]]` or after a malformed
        // header, where no key can belong to `hooks.state`.
        var table: [String]? = []
        var lines = toml.components(separatedBy: .newlines)[...]
        while let line = lines.popFirst() {
            var cursor = TOMLLineCursor(line)
            cursor.skipWhitespace()
            if cursor.peek == "[" {
                table = cursor.tableHeader()
                continue
            }
            guard let key = cursor.keyBeforeEquals() else { continue }
            cursor.skipWhitespace()
            if let delimiter = cursor.unclosedMultilineStringDelimiter() {
                // Skip the string's body so its lines are never read as headers or keys.
                while let next = lines.popFirst(), !next.contains(delimiter) {}
                continue
            }
            guard let table else { continue }
            let path = table + key
            guard path.count == 4, path[0] == "hooks", path[1] == "state",
                  path[2].hasPrefix(handlerPrefix), path[3] == "trusted_hash" else { continue }
            if let value = cursor.string(), !value.isEmpty { return true }
        }
        return false
    }
}

/// Reads the TOML key and string grammar from a single line: dotted keys built from bare, basic
/// (`"…"`) and literal (`'…'`) segments, and single-line string values.
private struct TOMLLineCursor {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ line: String) {
        scalars = Array(line.unicodeScalars)
    }

    var peek: Unicode.Scalar? {
        position < scalars.count ? scalars[position] : nil
    }

    mutating func skipWhitespace() {
        while let scalar = peek, scalar == " " || scalar == "\t" {
            position += 1
        }
    }

    /// The key path of a `[table]` header line, or nil for an `[[array table]]` or a malformed header.
    mutating func tableHeader() -> [String]? {
        guard consume("["), peek != "[" else { return nil }
        guard let key = dottedKey(), consume("]"), atLineEnd() else { return nil }
        return key
    }

    /// The key path of a `key = value` line, leaving the cursor just past the `=`.
    mutating func keyBeforeEquals() -> [String]? {
        guard let key = dottedKey(), consume("=") else { return nil }
        return key
    }

    /// The closing delimiter of a multi-line string that opens here and continues past this line.
    func unclosedMultilineStringDelimiter() -> String? {
        let rest = String(String.UnicodeScalarView(scalars[position...]))
        for delimiter in ["\"\"\"", "'''"] where rest.hasPrefix(delimiter) {
            return rest.dropFirst(3).contains(delimiter) ? nil : delimiter
        }
        return nil
    }

    /// A single-line basic or literal string value.
    mutating func string() -> String? {
        switch peek {
        case "\"": basicString()
        case "'": literalString()
        default: nil
        }
    }

    /// A dotted key, consuming the whitespace around each dot and after the last segment.
    private mutating func dottedKey() -> [String]? {
        var segments: [String] = []
        repeat {
            skipWhitespace()
            guard let segment = simpleKey() else { return nil }
            segments.append(segment)
            skipWhitespace()
        } while consume(".")
        return segments
    }

    private mutating func simpleKey() -> String? {
        if peek == "\"" || peek == "'" { return string() }
        let start = position
        while let scalar = peek, Self.isBareKeyScalar(scalar) {
            position += 1
        }
        guard position > start else { return nil }
        return String(String.UnicodeScalarView(scalars[start ..< position]))
    }

    private mutating func literalString() -> String? {
        guard consume("'") else { return nil }
        let start = position
        while let scalar = peek, scalar != "'" {
            position += 1
        }
        let value = String(String.UnicodeScalarView(scalars[start ..< position]))
        return consume("'") ? value : nil
    }

    private mutating func basicString() -> String? {
        guard consume("\"") else { return nil }
        var value = String.UnicodeScalarView()
        while let scalar = peek {
            position += 1
            switch scalar {
            case "\"":
                return String(value)
            case "\\":
                guard let escaped = escape() else { return nil }
                value.append(escaped)
            default:
                value.append(scalar)
            }
        }
        return nil
    }

    private mutating func escape() -> Unicode.Scalar? {
        guard let scalar = peek else { return nil }
        position += 1
        switch scalar {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "x": return hexScalar(digits: 2)
        case "u": return hexScalar(digits: 4)
        case "U": return hexScalar(digits: 8)
        default: return nil
        }
    }

    private mutating func hexScalar(digits: Int) -> Unicode.Scalar? {
        guard position + digits <= scalars.count else { return nil }
        let hex = String(String.UnicodeScalarView(scalars[position ..< position + digits]))
        position += digits
        return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init)
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek == scalar else { return false }
        position += 1
        return true
    }

    private mutating func atLineEnd() -> Bool {
        skipWhitespace()
        return peek == nil || peek == "#"
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "_", "-": true
        default: false
        }
    }
}
