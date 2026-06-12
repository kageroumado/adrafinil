import Foundation
import MachO

/// Detects whether the running executable's on-disk image has been replaced — the signal that an
/// in-place app update has swapped the bundle out from under a long-lived process.
///
/// A daemon or helper launched by `launchd` keeps running its original binary even after the app
/// bundle is updated: the file on disk is replaced, but the process executes from the image it was
/// launched with. With `KeepAlive` set, such a process can adopt the new binary simply by exiting —
/// `launchd` relaunches it from disk. This type provides the "should I exit?" signal.
///
/// The check is **identity-based, not version-based**: it records the executable file's
/// `(device, inode, size, mtime)` at launch and compares against the live file on demand. That
/// sidesteps any reliance on a compiled-in version string and catches *any* replacement (including a
/// same-version rebuild). It **fails safe** — if the path can't be read (e.g. observed mid-replace),
/// `hasBeenReplaced()` reports `false`, so a transient `stat` error never forces a needless restart.
public struct ExecutableStaleness: Sendable {
    private let path: String?
    private let launchSignature: Signature?

    private struct Signature: Equatable {
        let device: Int
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
    }

    /// Captures the running executable's identity. Construct **once at process launch** so the
    /// recorded signature reflects the binary the process is actually executing — a later
    /// construction would record whatever is on disk by then, which after an update is the new file.
    public init() {
        self.init(path: Self.runningExecutablePath())
    }

    /// Testable seam: record the signature of an arbitrary path.
    init(path: String?) {
        self.path = path
        self.launchSignature = Self.signature(ofPath: path)
    }

    /// True iff the file at the recorded path now differs from what it was at launch. Returns
    /// `false` whenever either signature is unreadable, so an unreadable path is never mistaken for
    /// a replacement.
    public func hasBeenReplaced() -> Bool {
        guard let launchSignature, let current = Self.signature(ofPath: path) else { return false }
        return current != launchSignature
    }

    private static func runningExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        // Resolve symlinks so the same physical file always yields the same path string; fall back
        // to the raw (already absolute) path if resolution fails.
        if let resolved = realpath(buffer, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
    }

    private static func signature(ofPath path: String?) -> Signature? {
        guard let path else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            device: Int(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSeconds: info.st_mtimespec.tv_sec,
            mtimeNanoseconds: info.st_mtimespec.tv_nsec,
        )
    }
}
