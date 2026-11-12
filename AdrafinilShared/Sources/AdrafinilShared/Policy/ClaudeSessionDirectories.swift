import Foundation

/// The set of Claude Code `sessions/` directories the daemon reads status files from: the default
/// `~/.claude/sessions` plus any non-default config directories learned from hooks.
///
/// A Claude Code profile run with `CLAUDE_CONFIG_DIR` (e.g. an alias pointing a second account at
/// `~/.claude-work`) writes its `<pid>.json` status files under that directory instead of
/// `~/.claude`. The daemon can't see a user's shell environment, but the hook can: `acquire --tool
/// claude-code` reports the `CLAUDE_CONFIG_DIR` it ran under, and the daemon registers it here.
///
/// The socket accepts any same-user caller, so a reported directory is untrusted input. It is only
/// accepted when, after standardizing (`.`/`..` removed, no symlink resolution), it is absolute,
/// strictly inside the home directory, not the default `~/.claude`, and has a `sessions`
/// subdirectory. The set is capped at `maxCount`; a re-report moves an entry to most-recent and the
/// oldest is evicted past the cap. Readers still apply `ClaudeSessionStatus.isStatusFilename`, so
/// nothing but `<pid>.json` is ever read from any of these directories.
///
/// In memory only: a daemon restart forgets learned directories, and the next acquire from that
/// profile registers it again.
public struct ClaudeSessionDirectories: Sendable {
    public static let maxCount = 8
    /// Longest reported path accepted — matches the frame-level limits on the other string fields.
    public static let maxPathLength = 1_024

    public let homeRoot: String
    /// Learned config directories (standardized), oldest first.
    public private(set) var learned: [String] = []

    /// Whether `<dir>/sessions` exists as a directory. Injected for tests.
    private let hasSessionsDirectory: @Sendable (String) -> Bool

    public init(
        homeRoot: String = NSHomeDirectory(),
        hasSessionsDirectory: @escaping @Sendable (String) -> Bool = Self.sessionsDirectoryExists,
    ) {
        self.homeRoot = URL(fileURLWithPath: homeRoot).standardized.path
        self.hasSessionsDirectory = hasSessionsDirectory
    }

    @Sendable
    public static func sessionsDirectoryExists(_ configDir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDir + "/sessions", isDirectory: &isDir) && isDir.boolValue
    }

    /// The default status directory, `~/.claude/sessions`.
    public var defaultSessionsDirectory: URL {
        URL(fileURLWithPath: homeRoot + "/.claude/sessions", isDirectory: true)
    }

    /// Every directory to read, default first, then learned ones oldest first.
    public var sessionsDirectories: [URL] {
        [defaultSessionsDirectory] + learned.map { URL(fileURLWithPath: $0 + "/sessions", isDirectory: true) }
    }

    /// The standardized config directory `raw` names, or nil if it fails validation (see the type
    /// doc). Does not touch the set.
    public func validated(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= Self.maxPathLength, raw.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: raw).standardized.path
        guard path.hasPrefix(homeRoot + "/"), path != homeRoot + "/.claude" else { return nil }
        guard hasSessionsDirectory(path) else { return nil }
        return path
    }

    /// Registers a reported config directory. Returns true when the set changed (a new entry, or an
    /// existing one moved to most-recent); false when `raw` was rejected or already most-recent.
    @discardableResult
    public mutating func register(_ raw: String?) -> Bool {
        guard let path = validated(raw) else { return false }
        if learned.last == path { return false }
        learned.removeAll { $0 == path }
        learned.append(path)
        if learned.count > Self.maxCount {
            learned.removeFirst(learned.count - Self.maxCount)
        }
        return true
    }
}
