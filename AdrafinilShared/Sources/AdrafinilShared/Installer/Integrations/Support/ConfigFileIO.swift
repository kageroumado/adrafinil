import Foundation

/// Shared filesystem helpers for the agent integrations: JSON config read/write, directory
/// creation, a human-readable before/after diff, and a PATH binary lookup. Every integration
/// reads → mutates → writes a copy, preserving any non-Adrafinil content the user already has.
enum ConfigFileIO {
    /// Reads a JSON object from `path`, or nil if it's missing or not a JSON dictionary.
    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Writes `dict` to `path` atomically, pretty-printed with sorted keys for stable diffs.
    static func writeJSON(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

    private static func serialized(_ dict: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// True if an executable named `name` exists on the current `PATH`. Used by binary-based detection
/// (Aider, Cline, OpenCode) where there's no well-known config directory to probe.
func binaryOnPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return true }
    }
    return false
}
