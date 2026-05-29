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

    @Test func runningProcessesIsNonEmptyAndIncludesSelf() {
        let procs = ProcessResolver.runningProcesses()
        #expect(!procs.isEmpty)
        #expect(procs.contains { $0.pid == getpid() })
    }
}
