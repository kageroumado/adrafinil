import Testing
import Foundation
@testable import AdrafinilShared

@Suite("AdrafinilSettings")
struct AdrafinilSettingsTests {

    @Test func defaultsAreSane() {
        let s = AdrafinilSettings()
        #expect(s.soundOnLidClose == true)
        #expect(s.thermalCutoutEnabled == true)
        #expect(s.thermalThresholdCelsius == 80.0)
        #expect(s.idleReleaseEnabled == true)
        #expect(s.idleReleaseSeconds == 90)
        #expect(s.processSniffingEnabled == true)
        #expect(s.autoAcquireForKnownAgents == false)
        #expect(s.launchAtLogin == true)
        #expect(s.showInMenuBar == true)
    }

    @Test func codableRoundtripPreservesAllFields() throws {
        var original = AdrafinilSettings()
        original.soundOnLidClose = false
        original.soundVolume = 0.25
        original.thermalThresholdCelsius = 72.5
        original.idleReleaseSeconds = 120
        original.autoAcquireForKnownAgents = true
        original.chimeName = "doot"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdrafinilSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func saveAndLoadRoundtripViaDisk() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = AdrafinilSettings()
        settings.thermalThresholdCelsius = 85
        settings.idleReleaseSeconds = 120

        try settings.save(to: tempURL)
        let loaded = AdrafinilSettings.load(from: tempURL)
        #expect(loaded == settings)
    }

    @Test func loadFromMissingFileReturnsDefaults() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let loaded = AdrafinilSettings.load(from: missing)
        #expect(loaded == AdrafinilSettings())
    }

    /// Regression: a config written by an older build (missing a newer field) must not
    /// throw and reset *all* settings. Each absent field should fall back to its default
    /// while user-set fields are preserved.
    @Test func missingNewFieldFallsBackWithoutLosingOthers() throws {
        let json = Data(#"""
        {"soundOnLidClose": false, "soundVolume": 0.25, "chimeName": "Tink",
         "thermalCutoutEnabled": false, "thermalThresholdCelsius": 72.5,
         "idleReleaseEnabled": false, "idleReleaseSeconds": 150,
         "processSniffingEnabled": false, "autoAcquireForKnownAgents": true,
         "launchAtLogin": false}
        """#.utf8)
        let s = try JSONDecoder().decode(AdrafinilSettings.self, from: json)
        #expect(s.idleReleaseSeconds == 150)
        #expect(s.thermalThresholdCelsius == 72.5)
        #expect(s.launchAtLogin == false)
        #expect(s.chimeName == "Tink")
        #expect(s.showInMenuBar == true)  // absent → default, not a decode failure
    }

    @Test func emptyObjectDecodesToAllDefaults() throws {
        let s = try JSONDecoder().decode(AdrafinilSettings.self, from: Data("{}".utf8))
        #expect(s == AdrafinilSettings())
    }

    @Test func unknownExtraKeysAreIgnored() throws {
        let s = try JSONDecoder().decode(AdrafinilSettings.self,
                                         from: Data(#"{"idleReleaseSeconds": 70, "futureSetting": 123}"#.utf8))
        #expect(s.idleReleaseSeconds == 70)
    }

    @Test func loadFromDiskMissingNewFieldPreservesUserValues() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"idleReleaseSeconds": 220, "thermalThresholdCelsius": 90}"#.utf8).write(to: url)
        let loaded = AdrafinilSettings.load(from: url)
        #expect(loaded.idleReleaseSeconds == 220)
        #expect(loaded.thermalThresholdCelsius == 90)
        #expect(loaded.showInMenuBar == true)
    }

    /// A config from a build that only knew `idleReleaseMinutes` migrates to the seconds field (×60).
    @Test func legacyMinutesMigratesToSeconds() throws {
        let s = try JSONDecoder().decode(AdrafinilSettings.self,
                                         from: Data(#"{"idleReleaseMinutes": 3}"#.utf8))
        #expect(s.idleReleaseSeconds == 180)
        // An explicit seconds field wins over a stale minutes field if both somehow appear.
        let both = try JSONDecoder().decode(AdrafinilSettings.self,
                                            from: Data(#"{"idleReleaseMinutes": 3, "idleReleaseSeconds": 45}"#.utf8))
        #expect(both.idleReleaseSeconds == 45)
    }
}
