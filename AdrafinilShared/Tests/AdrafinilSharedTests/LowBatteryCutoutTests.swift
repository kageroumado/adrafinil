import Testing
@testable import AdrafinilShared

@Suite("LowBatteryCutoutEvaluator")
struct LowBatteryCutoutTests {
    private let e = LowBatteryCutoutEvaluator()

    @Test("fires on battery, lid closed, blocking, at/under threshold")
    func firesWhenAllGatesOpen() {
        #expect(e.shouldCutout(batteryPercent: 15, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("battery exactly at threshold fires")
    func boundaryEqualThresholdFires() {
        #expect(e.shouldCutout(batteryPercent: 20, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("above threshold does not fire")
    func aboveThresholdNoFire() {
        #expect(!e.shouldCutout(batteryPercent: 21, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("each gate individually closed suppresses the cutout even at empty battery")
    func gatesSuppress() {
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: false, enabled: true, lidClosed: true, isBlocking: true))  // on AC
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: false, lidClosed: true, isBlocking: true))  // disabled
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: false, isBlocking: true))  // lid open
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: false))  // not blocking
    }
}
