import Foundation
import Testing
@testable import AdrafinilShared

/// The latch prevents the acquire → cutout → release → re-acquire oscillation: a cutout's
/// rejection of new acquires must hold until the hazard genuinely recedes (with hysteresis) or
/// the lid opens.
@Suite("CutoutLatch")
struct CutoutLatchTests {
    @Test
    func `tripping latches and produces a rejection message`() {
        var latch = CutoutLatch()
        #expect(!latch.isLatched)
        #expect(latch.rejectionMessage == nil)
        latch.trip(.thermal)
        #expect(latch.isLatched)
        #expect(latch.rejectionMessage != nil)
    }

    @Test
    func `thermal latch holds at the threshold and clears only past hysteresis`() {
        var latch = CutoutLatch()
        latch.trip(.thermal)

        // Just under the threshold is not enough — that's the oscillation the latch exists for.
        latch.update(temperatureCelsius: 79, thermalThresholdCelsius: 80, batteryPercent: nil, onBattery: nil, batteryThresholdPercent: 20, lidClosed: true)
        #expect(latch.isLatched)

        // At threshold − hysteresis it clears.
        let cleared = latch.update(temperatureCelsius: 75, thermalThresholdCelsius: 80, batteryPercent: nil, onBattery: nil, batteryThresholdPercent: 20, lidClosed: true)
        #expect(cleared == [.thermal])
        #expect(!latch.isLatched)
    }

    @Test
    func `battery latch clears on AC or with charge margin, not on a missing reading`() {
        var latch = CutoutLatch()
        latch.trip(.lowBattery)

        // Unknown readings keep the latch — a cutout must not clear on missing data.
        latch.update(temperatureCelsius: nil, thermalThresholdCelsius: 80, batteryPercent: nil, onBattery: nil, batteryThresholdPercent: 20, lidClosed: true)
        #expect(latch.isLatched)

        // Still on battery, barely above threshold — not enough margin.
        latch.update(temperatureCelsius: nil, thermalThresholdCelsius: 80, batteryPercent: 22, onBattery: true, batteryThresholdPercent: 20, lidClosed: true)
        #expect(latch.isLatched)

        // Plugged in clears immediately.
        let cleared = latch.update(temperatureCelsius: nil, thermalThresholdCelsius: 80, batteryPercent: 22, onBattery: false, batteryThresholdPercent: 20, lidClosed: true)
        #expect(cleared == [.lowBattery])
    }

    @Test
    func `opening the lid clears every cause`() {
        var latch = CutoutLatch()
        latch.trip(.thermal)
        latch.trip(.lowBattery)
        let cleared = latch.update(temperatureCelsius: nil, thermalThresholdCelsius: 80, batteryPercent: nil, onBattery: nil, batteryThresholdPercent: 20, lidClosed: false)
        #expect(cleared == [.thermal, .lowBattery])
        #expect(!latch.isLatched)
    }

    @Test
    func `causes clear independently`() {
        var latch = CutoutLatch()
        latch.trip(.thermal)
        latch.trip(.lowBattery)
        // Cool but still draining: thermal clears, battery stays.
        let cleared = latch.update(temperatureCelsius: 60, thermalThresholdCelsius: 80, batteryPercent: 15, onBattery: true, batteryThresholdPercent: 20, lidClosed: true)
        #expect(cleared == [.thermal])
        #expect(latch.active == [.lowBattery])
    }
}

@Suite("AdrafinilSettings hardening")
struct SettingsHardeningTests {
    @Test
    func `a type-mismatched field costs only that field`() throws {
        let json = """
        {"idleReleaseSeconds": "ninety", "thermalThresholdCelsius": 85, "launchAtLogin": false}
        """
        let s = try JSONDecoder().decode(AdrafinilSettings.self, from: Data(json.utf8))
        #expect(s.idleReleaseSeconds == AdrafinilSettings().idleReleaseSeconds, "the bad field falls back to default")
        #expect(s.thermalThresholdCelsius == 85, "good fields survive")
        #expect(!s.launchAtLogin, "good fields survive")
    }

    @Test
    func `out-of-range values are clamped on load`() throws {
        let json = """
        {"lowBatteryThresholdPercent": 150, "thermalThresholdCelsius": 0, "idleReleaseSeconds": -5, "manualHoldMaxHours": -1, "soundVolume": 9}
        """
        let s = try JSONDecoder().decode(AdrafinilSettings.self, from: Data(json.utf8))
        #expect(s.lowBatteryThresholdPercent == 99, "150% would fire the cutout on every tick")
        #expect(s.thermalThresholdCelsius == 50)
        #expect(s.idleReleaseSeconds == 30)
        #expect(s.manualHoldMaxHours == 0.25)
        #expect(s.soundVolume == 1)
    }
}
