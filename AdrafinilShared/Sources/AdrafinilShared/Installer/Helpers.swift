import Foundation

/// PATH lookup for known binaries. Used by HookSpec.isDetected().
func binaryOnPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return true }
    }
    return false
}
