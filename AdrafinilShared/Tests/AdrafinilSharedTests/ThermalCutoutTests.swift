import Testing
@testable import AdrafinilShared

@Suite("ThermalCutoutEvaluator")
struct ThermalCutoutTests {
    private let e = ThermalCutoutEvaluator()

    @Test("fires when enabled, lid closed, blocking, and at/over threshold")
    func firesWhenAllGatesOpen() {
        #expect(e.shouldCutout(temperatureCelsius: 85, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("temperature exactly at threshold fires")
    func boundaryEqualThresholdFires() {
        #expect(e.shouldCutout(temperatureCelsius: 80, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("below threshold does not fire")
    func belowThresholdNoFire() {
        #expect(!e.shouldCutout(temperatureCelsius: 79.9, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test("each gate individually closed suppresses the cutout even when scorching")
    func gatesSuppress() {
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: false, lidClosed: true, isBlocking: true))
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: true, lidClosed: false, isBlocking: true))
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: false))
    }
}
