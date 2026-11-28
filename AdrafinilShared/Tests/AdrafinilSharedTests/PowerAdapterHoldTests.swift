import Foundation
import Testing
@testable import AdrafinilShared

@Suite("PowerAdapterHold")
struct PowerAdapterHoldTests {
    private func decide(
        enabled: Bool = true,
        onBattery: Bool? = false,
        paused: Bool = false,
        latched: Bool = false,
        suppressed: Bool = false,
        held: Bool = false,
    ) -> PowerAdapterHold.Action {
        PowerAdapterHold.decide(
            enabled: enabled,
            onBattery: onBattery,
            paused: paused,
            latched: latched,
            suppressed: suppressed,
            held: held,
        )
    }

    @Test
    func `places the hold on the power adapter when enabled`() {
        #expect(decide() == .place)
    }

    @Test
    func `keeps an existing hold while still on the power adapter`() {
        #expect(decide(held: true) == .none)
    }

    @Test
    func `releases the hold the moment the Mac goes on battery`() {
        #expect(decide(onBattery: true, held: true) == .release)
        #expect(decide(onBattery: true, held: false) == .none)
    }

    @Test
    func `never holds without a power-source reading, as on a desktop Mac`() {
        #expect(decide(onBattery: nil) == .none)
        #expect(decide(onBattery: nil, held: true) == .release)
    }

    @Test
    func `each blocker on its own keeps the hold off, and releases one already held`() {
        #expect(decide(enabled: false) == .none)
        #expect(decide(enabled: false, held: true) == .release)
        #expect(decide(paused: true) == .none)
        #expect(decide(paused: true, held: true) == .release)
        #expect(decide(latched: true) == .none)
        #expect(decide(suppressed: true) == .none)
        #expect(decide(suppressed: true, held: true) == .release)
    }

    @Test
    func `the hold has no process and no deadline, so only the power source ends it`() {
        let a = PowerAdapterHold.assertion(now: Date(timeIntervalSince1970: 1_000))
        #expect(a.key == PowerAdapterHold.key)
        #expect(a.pid <= 0)
        #expect(a.expiresAt == nil)
        #expect(a.origin == .manual)
        #expect(!a.holdsDisplay)
    }

    @Test
    func `only assertions other than the power-adapter hold count as agent work`() {
        let power = PowerAdapterHold.assertion()
        let agent = Assertion(key: "claude-code:s1", tool: "claude-code", pid: 42, processName: "claude")
        #expect(!PowerAdapterHold.holdsAgentWork([]))
        #expect(!PowerAdapterHold.holdsAgentWork([power]))
        #expect(PowerAdapterHold.holdsAgentWork([power, agent]))
        #expect(PowerAdapterHold.holdsAgentWork([agent]))
    }

    @Test
    func `the key is reserved: an external acquire cannot plant or impersonate it`() {
        #expect(PowerAdapterHold.isKey("power:adapter"))
        #expect(!PowerAdapterHold.isKey(ManualHold.newKey()))
        // A hook naming itself `power` would mint exactly this key; the socket refuses it.
        let planted = ManualHold.sessionKey(tool: "power", sessionID: "adapter")
        #expect(planted == PowerAdapterHold.key)
        #expect(CLIRequestValidator.acquireRejection(key: planted, tool: "power") != nil)
    }
}
