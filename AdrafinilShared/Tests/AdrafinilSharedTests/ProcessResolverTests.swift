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
}
