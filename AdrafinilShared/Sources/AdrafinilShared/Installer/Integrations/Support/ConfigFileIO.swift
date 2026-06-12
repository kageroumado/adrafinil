import Foundation

/// Shared filesystem helpers for the agent integrations: JSON config read/write, directory
/// creation, a human-readable before/after diff, and a PATH binary lookup. Every integration
/// reads → mutates → writes a copy, preserving any non-Adrafinil content the user already has.
///
/// These files are owned by *other programs* and shared with user content, so the helpers are
/// deliberately defensive: a file that exists but can't be parsed is an error (writing a fresh
/// object over it would destroy the user's content), writes go through symlinks rather than
/// replacing them (dotfile managers like stow/chezmoi symlink these configs), and the original
/// file's permissions survive the atomic replace.
enum ConfigFileIO {
    /// What was found at a config path.
    enum ReadResult {
        case missing
        /// The file exists but couldn't be read or parsed as a JSON object — a comment-bearing
        /// (jsonc) settings file, a syntax error mid-edit, an array root, or a permission error.
        case unparseable
        case object([String: Any])
    }

    static func read(_ path: String) -> ReadResult {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unparseable }
        return .object(obj)
    }

    /// Reads a JSON object for a read-modify-write cycle. Missing file → nil (caller starts
    /// fresh); existing-but-unparseable file → throws, because the subsequent write would
    /// replace the user's content with only our entries.
    static func readJSONForUpdate(_ path: String) throws -> [String: Any]? {
        switch read(path) {
        case .missing: return nil
        case let .object(obj): return obj
        case .unparseable: throw HookInstaller.SkipReason.configUnreadable(path)
        }
    }

    /// Writes `dict` to `path` atomically, pretty-printed with sorted keys for stable diffs.
    ///
    /// `replacing` is the object the caller read at the start of its read-modify-write cycle
    /// (nil when the file didn't exist). The file is re-read just before writing: if another
    /// process changed it in between — agents rewrite their own configs during sessions —
    /// the write is refused instead of silently dropping that change.
    static func writeJSON(_ dict: [String: Any], to path: String, replacing before: [String: Any]?) throws {
        switch read(path) {
        case .missing:
            guard before == nil else { throw HookInstaller.SkipReason.concurrentModification(path) }
        case .unparseable:
            throw HookInstaller.SkipReason.concurrentModification(path)
        case let .object(current):
            guard let before, NSDictionary(dictionary: current).isEqual(to: before) else {
                throw HookInstaller.SkipReason.concurrentModification(path)
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
        try writeThroughSymlinks(data, to: path)
    }

    /// Writes a string config (YAML, rc files, plugin sources) through the same safe path.
    static func writeString(_ string: String, to path: String) throws {
        try writeThroughSymlinks(Data(string.utf8), to: path)
    }

    /// Atomic write that resolves symlinks first (so a stow/chezmoi-managed config keeps its
    /// link and the dotfiles repo keeps tracking reality) and restores the original POSIX
    /// permissions afterwards (an atomic replace would otherwise reset a 0600 settings file
    /// holding keys to the umask default).
    private static func writeThroughSymlinks(_ data: Data, to path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fm = FileManager.default
        let originalPerms = (try? fm.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? NSNumber
        try data.write(to: resolved, options: .atomic)
        if let originalPerms {
            try? fm.setAttributes([.posixPermissions: originalPerms], ofItemAtPath: resolved.path)
        }
    }

    /// Creates the parent directory of `filePath` (and any intermediates) if needed.
    static func ensureParentDir(of filePath: String) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Returns a `BEFORE/AFTER` diff of two JSON objects, or `(unchanged)` when they serialize equal.
    static func makeDiff(before: [String: Any], after: [String: Any]) -> String {
        let beforeStr = serialized(before)
        let afterStr = serialized(after)
        if beforeStr == afterStr { return "(unchanged)" }
        return "BEFORE:\n\(beforeStr)\n---\nAFTER:\n\(afterStr)"
    }

    /// Whether a hook command invokes the adrafinil CLI. Recognizes entries written before the
    /// `_adrafinil` tag existed, or where a tag isn't allowed (Codex rejects unknown keys), even
    /// when the embedded CLI path has since drifted. A command must call an adrafinil binary
    /// with one of our verbs and `--tool` — merely containing the word (a user's own
    /// `adrafinil-notify.sh`) doesn't make it ours to rewrite or delete.
    static func commandInvokesAdrafinilCLI(_ command: String?) -> Bool {
        guard let command, command.contains("adrafinil"), command.contains("--tool") else { return false }
        return [" acquire", " release", " hold"].contains { command.contains($0) }
    }

    private static func serialized(_ dict: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// True if an executable named `name` exists on the current `PATH`, or in the standard install
/// locations a GUI app's launchd-provided PATH misses (Homebrew, ~/.local/bin). Used by
/// binary-based detection (Aider, Cline, OpenCode) where there's no config directory to probe.
func binaryOnPath(_ name: String) -> Bool {
    let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let fallbackDirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
    for dir in pathDirs + fallbackDirs {
        if FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return true }
    }
    return false
}
