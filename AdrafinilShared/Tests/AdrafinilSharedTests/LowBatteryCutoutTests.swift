import Testing
@testable import AdrafinilShared

@Suite("LowBatteryCutoutEvaluator")
struct LowBatteryCutoutTests {
    private let e = LowBatteryCutoutEvaluator()

    @Test
    func `fires on battery, lid closed, blocking, at/under threshold`() {
        #expect(e.shouldCutout(batteryPercent: 15, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `battery exactly at threshold fires`() {
        #expect(e.shouldCutout(batteryPercent: 20, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `above threshold does not fire`() {
        #expect(!e.shouldCutout(batteryPercent: 21, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `each gate individually closed suppresses the cutout even at empty battery`() {
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: false, enabled: true, lidClosed: true, isBlocking: true)) // on AC
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: false, lidClosed: true, isBlocking: true)) // disabled
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: false, isBlocking: true)) // lid open
        #expect(!e.shouldCutout(batteryPercent: 1, thresholdPercent: 20, onBattery: true, enabled: true, lidClosed: true, isBlocking: false)) // not blocking
    }
}
