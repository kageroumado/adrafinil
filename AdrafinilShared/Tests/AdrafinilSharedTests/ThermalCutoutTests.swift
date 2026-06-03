import Testing
@testable import AdrafinilShared

@Suite("ThermalCutoutEvaluator")
struct ThermalCutoutTests {
    private let e = ThermalCutoutEvaluator()

    @Test
    func `fires when enabled, lid closed, blocking, and at/over threshold`() {
        #expect(e.shouldCutout(temperatureCelsius: 85, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `temperature exactly at threshold fires`() {
        #expect(e.shouldCutout(temperatureCelsius: 80, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `below threshold does not fire`() {
        #expect(!e.shouldCutout(temperatureCelsius: 79.9, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: true))
    }

    @Test
    func `each gate individually closed suppresses the cutout even when scorching`() {
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: false, lidClosed: true, isBlocking: true))
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: true, lidClosed: false, isBlocking: true))
        #expect(!e.shouldCutout(temperatureCelsius: 99, thresholdCelsius: 80, enabled: true, lidClosed: true, isBlocking: false))
    }
}
