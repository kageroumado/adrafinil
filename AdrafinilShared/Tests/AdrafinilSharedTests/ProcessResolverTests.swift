import Testing
import Foundation
@testable import AdrafinilShared

@Suite("ProcessResolver")
struct ProcessResolverTests {

    @Test func nameOfCurrentProcessIsNonNil() {
        let name = ProcessResolver.name(of: getpid())
        #expect(name != nil)
        #expect(!(name ?? "").isEmpty)
    }

    @Test func nameOfInvalidPidIsNil() {
        #expect(ProcessResolver.name(of: -1) == nil)
    }

    @Test func parentOfCurrentProcessIsPositive() {
        #expect(ProcessResolver.parentPID(of: getpid()) > 0)
    }

    @Test func owningAgentPIDWithEmptyBinarySetIsNegative() {
        // No candidate names → never matches → -1 (daemon then declines to process-watch).
        #expect(ProcessResolver.owningAgentPID(binaryNames: []) == -1)
    }

    @Test func owningAgentPIDWithUnmatchableNameIsNegative() {
        #expect(ProcessResolver.owningAgentPID(binaryNames: ["definitely-not-a-real-binary-xyzzy"]) == -1)
    }

    @Test func pathMatchesAgentByBasename() {
        #expect(ProcessResolver.pathMatchesAgent("/usr/local/bin/codex", names: ["codex"]))
    }

    @Test func pathMatchesAgentByPathComponentForVersionedInstall() {
        // Claude installs at …/claude/versions/<x.y.z>; basename is a version, but the "claude"
        // path component must still match (the bug that left Claude unwatchable, pid=-1).
        let p = "/Users/u/.local/share/claude/versions/2.1.156"
        #expect(ProcessResolver.pathMatchesAgent(p, names: ["claude"]))
    }

    @Test func pathMatchesAgentRejectsUnrelatedPath() {
        #expect(!ProcessResolver.pathMatchesAgent("/usr/bin/python3", names: ["claude", "codex"]))
    }

    @Test func runningProcessesIsNonEmptyAndIncludesSelf() {
        let procs = ProcessResolver.runningProcesses()
        #expect(!procs.isEmpty)
        #expect(procs.contains { $0.pid == getpid() })
    }

    // MARK: - gatewayPID

    @Test func gatewayPIDMissingFileIsNegative() {
        #expect(ProcessResolver.gatewayPID(pidFilePath: "/no/such/gateway.pid") == -1)
    }

    @Test func gatewayPIDParsesLiveJSONPid() throws {
        // Hermes writes {"pid": N, "kind": "hermes-gateway", …}. Our own pid is guaranteed alive.
        let file = NSTemporaryDirectory() + "gw-\(getpid())-json.pid"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try #"{"pid": \#(getpid()), "kind": "hermes-gateway"}"#.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(pidFilePath: file) == getpid())
    }

    @Test func gatewayPIDParsesLiveBareIntPid() throws {
        let file = NSTemporaryDirectory() + "gw-\(getpid())-bare.pid"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "\(getpid())\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(pidFilePath: file) == getpid())
    }

    @Test func gatewayPIDRejectsDeadPid() throws {
        // A stale pid-file pointing at a long-dead PID must resolve to -1, not a recycled process.
        let file = NSTemporaryDirectory() + "gw-stale.pid"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try #"{"pid": 2147483600}"#.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(pidFilePath: file) == -1)
    }

    // MARK: - gatewayPID (profile-aware: default + profiles/*/gateway.pid)

    private func makeHermesHome() throws -> String {
        let home = NSTemporaryDirectory() + "hh-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.hermes", withIntermediateDirectories: true)
        return home
    }

    @Test func gatewayPIDProfileAwarePrefersDefault() throws {
        let home = try makeHermesHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Default pid-file is live (our own pid) → used directly, profiles not consulted.
        try #"{"pid": \#(getpid())}"#.write(toFile: home + "/.hermes/gateway.pid", atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(homeRoot: home, pidFileRelativePath: ".hermes/gateway.pid") == getpid())
    }

    @Test func gatewayPIDProfileAwareFindsProfileWhenDefaultMissing() throws {
        let home = try makeHermesHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // No default pid-file; a named profile has a live gateway → found via the profiles glob.
        let prof = home + "/.hermes/profiles/work"
        try FileManager.default.createDirectory(atPath: prof, withIntermediateDirectories: true)
        try #"{"pid": \#(getpid()), "kind": "hermes-gateway"}"#.write(toFile: prof + "/gateway.pid", atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(homeRoot: home, pidFileRelativePath: ".hermes/gateway.pid") == getpid())
    }

    @Test func gatewayPIDProfileAwareSkipsDeadProfileGateways() throws {
        let home = try makeHermesHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // A profile whose gateway is dead must not match (stale pid file).
        let prof = home + "/.hermes/profiles/dead"
        try FileManager.default.createDirectory(atPath: prof, withIntermediateDirectories: true)
        try #"{"pid": 2147483600}"#.write(toFile: prof + "/gateway.pid", atomically: true, encoding: .utf8)
        #expect(ProcessResolver.gatewayPID(homeRoot: home, pidFileRelativePath: ".hermes/gateway.pid") == -1)
    }

    @Test func gatewayPIDProfileAwareNoneReturnsNegative() throws {
        let home = try makeHermesHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // No pid-files anywhere (not even a profiles dir) → -1, no crash.
        #expect(ProcessResolver.gatewayPID(homeRoot: home, pidFileRelativePath: ".hermes/gateway.pid") == -1)
    }
}
