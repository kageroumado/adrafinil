import Foundation
import Testing
@testable import AdrafinilShared

@Suite("ProcessActivityGate")
struct ProcessActivityGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func `first sighting is never active`() {
        let gate = ProcessActivityGate()
        // No prior sample → a rate can't be computed, so a freshly-seen daemon is never acquired.
        #expect(gate.isActive(pid: 42, treeCPU: 100, now: t0) == false)
    }

    @Test
    func `sustained high rate is active`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0) // seed
        // +15 CPU-seconds over 30s wall = 0.5 of a core → well above the 3% threshold.
        #expect(gate.isActive(pid: 42, treeCPU: 115, now: t0.addingTimeInterval(30)) == true)
    }

    @Test
    func `idle tree is inactive`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0) // seed
        // +0.3 CPU-seconds over 30s = 1% of a core → below 3%, an idle daemon between turns.
        #expect(gate.isActive(pid: 42, treeCPU: 100.3, now: t0.addingTimeInterval(30)) == false)
    }

    @Test
    func `rate is measured against previous sample not first`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0)
        // A busy sweep advances the baseline...
        #expect(gate.isActive(pid: 42, treeCPU: 130, now: t0.addingTimeInterval(30)) == true)
        // ...so a subsequent idle sweep reads as idle (rate from 130, not from the original 100).
        #expect(gate.isActive(pid: 42, treeCPU: 130.1, now: t0.addingTimeInterval(60)) == false)
    }

    @Test
    func `non positive delta is inactive`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0)
        #expect(gate.isActive(pid: 42, treeCPU: 999, now: t0) == false) // same instant → dt == 0
    }

    @Test
    func `forget resets baseline for recycled pid`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0)
        gate.forget(keeping: []) // pid 42 exited
        // A recycled pid 42 with a low CPU total must not read as a spurious rate from the old 100
        // baseline — it re-seeds and reports inactive on first sight.
        #expect(gate.isActive(pid: 42, treeCPU: 5, now: t0.addingTimeInterval(30)) == false)
    }

    @Test
    func `custom threshold is honored`() {
        let gate = ProcessActivityGate()
        _ = gate.isActive(pid: 42, treeCPU: 100, now: t0)
        // +3 CPU-seconds over 30s = 10% of a core: active at 3% default, idle at a 20% threshold.
        #expect(gate.isActive(pid: 42, treeCPU: 103, now: t0.addingTimeInterval(30), rateThreshold: 0.20) == false)
        gate.forget(keeping: [42])
        _ = gate.isActive(pid: 7, treeCPU: 100, now: t0)
        #expect(gate.isActive(pid: 7, treeCPU: 103, now: t0.addingTimeInterval(30), rateThreshold: 0.05) == true)
    }
}
