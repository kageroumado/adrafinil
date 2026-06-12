import Foundation
import Testing
@testable import AdrafinilShared

/// `ExecutableStaleness` is how a long-lived daemon/helper notices that an in-place app update has
/// replaced its binary on disk, so it can exit and let `launchd` relaunch the new image. The signal
/// must fire on replacement and — critically — never false-positive, since a spurious "replaced"
/// would restart a service that's actively keeping the Mac awake.
@Suite("ExecutableStaleness")
struct ExecutableStalenessTests {
    private func makeTempFile(contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("staleness-\(UUID().uuidString)").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test
    func `an untouched file is not seen as replaced`() throws {
        let path = try makeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ExecutableStaleness(path: path)
        #expect(!monitor.hasBeenReplaced())
        // Repeated checks stay stable.
        #expect(!monitor.hasBeenReplaced())
    }

    @Test
    func `overwriting the file with different content is detected as a replacement`() throws {
        let path = try makeTempFile(contents: "v1")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ExecutableStaleness(path: path)
        #expect(!monitor.hasBeenReplaced())
        try "a much longer second version".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(monitor.hasBeenReplaced())
    }

    @Test
    func `replacing the file via a fresh inode is detected`() throws {
        let path = try makeTempFile(contents: "first generation contents")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ExecutableStaleness(path: path)
        // Remove and recreate — atomic-write replacement swaps the inode, the way Finder's "Replace"
        // installs a new app bundle.
        try FileManager.default.removeItem(atPath: path)
        try "second generation, different length".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(monitor.hasBeenReplaced())
    }

    @Test
    func `a nil path never reports a replacement`() {
        let monitor = ExecutableStaleness(path: nil)
        #expect(!monitor.hasBeenReplaced())
    }

    @Test
    func `a path that never existed never reports a replacement`() {
        let monitor = ExecutableStaleness(path: "/nonexistent/\(UUID().uuidString)/binary")
        #expect(!monitor.hasBeenReplaced())
    }

    @Test
    func `a file deleted after launch fails safe rather than reporting a replacement`() throws {
        let path = try makeTempFile(contents: "present at launch")
        let monitor = ExecutableStaleness(path: path)
        #expect(!monitor.hasBeenReplaced())
        // Mid-replace a process can momentarily observe the path gone; that must not be read as a
        // replacement (which would needlessly restart a possibly-blocking service).
        try FileManager.default.removeItem(atPath: path)
        #expect(!monitor.hasBeenReplaced())
    }

    @Test
    func `the no-argument initializer reads the running test binary without crashing`() {
        // Smoke test of the real _NSGetExecutablePath path: the running xctest binary isn't being
        // replaced, so it must read as not-replaced.
        let monitor = ExecutableStaleness()
        #expect(!monitor.hasBeenReplaced())
    }
}
