import Testing
import Foundation
@testable import AdrafinilShared

@Suite("SleepBlockPolicy")
struct SleepBlockPolicyTests {

    /// Models the real idle assertion: `acquire()` is idempotent (the production conformer guards
    /// on a non-zero assertion id), so a double-acquire holds exactly one assertion.
    final class FakeIdle: IdleSleepAsserting {
        private(set) var isHeld = false
        private(set) var acquireCount = 0
        private(set) var releaseCount = 0
        func acquire() {
            guard !isHeld else { return }
            acquireCount += 1
            isHeld = true
        }
        func release() {
            guard isHeld else { return }
            releaseCount += 1
            isHeld = false
        }
    }

    final class FakeClamshell: ClamshellSleepControlling {
        struct Boom: Error {}
        private(set) var calls: [Bool] = []
        /// When set, `setDisabled(throwOn)` throws.
        var throwOn: Bool?
        func setDisabled(_ disabled: Bool) throws {
            if let throwOn, throwOn == disabled { throw Boom() }
            calls.append(disabled)
        }
    }

    @Test("init clears any stale clamshell block (crash recovery)")
    func initClearsStaleClamshell() {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        #expect(clam.calls == [false])
        #expect(!policy.isBlocked)
        #expect(!idle.isHeld)
    }

    @Test("set(true) acquires the idle assertion and disables clamshell sleep")
    func setTrueBlocks() throws {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        try policy.set(blocked: true)
        #expect(idle.acquireCount == 1)
        #expect(idle.isHeld)
        #expect(clam.calls == [false, true])   // init-clear, then block
        #expect(policy.isBlocked)
    }

    @Test("set(false) releases the idle assertion and clears clamshell sleep")
    func setFalseUnblocks() throws {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        try policy.set(blocked: true)
        try policy.set(blocked: false)
        #expect(idle.releaseCount == 1)
        #expect(!idle.isHeld)
        #expect(clam.calls == [false, true, false])
        #expect(!policy.isBlocked)
    }

    @Test("repeated set(true) re-asserts clamshell but does not double-acquire the assertion")
    func repeatedSetTrueReassertsWithoutDoubleAcquire() throws {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        try policy.set(blocked: true)
        try policy.set(blocked: true)
        #expect(idle.acquireCount == 1)            // idempotent acquire
        #expect(clam.calls == [false, true, true]) // clamshell re-asserted (wake recovery)
        #expect(policy.isBlocked)
    }

    @Test("a clamshell failure while blocking propagates")
    func throwOnBlockPropagates() {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        clam.throwOn = true
        #expect(throws: FakeClamshell.Boom.self) {
            try policy.set(blocked: true)
        }
        #expect(!policy.isBlocked)   // block did not complete
        #expect(idle.isHeld)         // but the idle assertion was already acquired (matches original)
    }

    @Test("a clamshell failure while unblocking is swallowed (best-effort clear)")
    func throwOnUnblockIsSwallowed() throws {
        let idle = FakeIdle(), clam = FakeClamshell()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam)
        try policy.set(blocked: true)
        clam.throwOn = false
        try policy.set(blocked: false)   // must not throw
        #expect(!policy.isBlocked)
        #expect(!idle.isHeld)
    }
}
