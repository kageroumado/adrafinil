import Foundation

public struct AdrafinilSettings: Codable, Sendable, Equatable {
    public var soundOnLidClose: Bool = true
    public var soundVolume: Float = 0.5
    public var chimeName: String = "default"

    /// Lock the screen when the lid closes while an agent is active, so the awake machine is
    /// still secured. Issues an explicit lock (overrides idle-lock-prevention from other apps).
    public var lockOnLidClose: Bool = true

    public var thermalCutoutEnabled: Bool = true
    public var thermalThresholdCelsius: Double = 80.0

    /// Force-release all assertions when, on battery with the lid closed, the charge falls to or
    /// below this percentage — so a kept-awake Mac can sleep normally instead of draining to a
    /// hard shutdown in a bag (the battery sibling of the thermal cutout).
    public var lowBatteryCutoutEnabled: Bool = true
    public var lowBatteryThresholdPercent: Int = 20

    public var idleReleaseEnabled: Bool = true
    public var idleReleaseMinutes: Int = 5

    public var processSniffingEnabled: Bool = true
    public var autoAcquireForKnownAgents: Bool = false

    public var launchAtLogin: Bool = true
    public var showInMenuBar: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case soundOnLidClose, soundVolume, chimeName, lockOnLidClose
        case thermalCutoutEnabled, thermalThresholdCelsius
        case lowBatteryCutoutEnabled, lowBatteryThresholdPercent
        case idleReleaseEnabled, idleReleaseMinutes
        case processSniffingEnabled, autoAcquireForKnownAgents
        case launchAtLogin, showInMenuBar
    }

    /// Resilient decoding: a missing key falls back to its default rather than throwing.
    /// Swift's synthesized decoder throws on any absent key, which would make `load()`
    /// discard a user's *entire* config the moment a newer build adds a setting. Decoding
    /// each field independently keeps old config files forward-compatible.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdrafinilSettings()
        soundOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .soundOnLidClose) ?? d.soundOnLidClose
        soundVolume = try c.decodeIfPresent(Float.self, forKey: .soundVolume) ?? d.soundVolume
        chimeName = try c.decodeIfPresent(String.self, forKey: .chimeName) ?? d.chimeName
        lockOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose) ?? d.lockOnLidClose
        thermalCutoutEnabled = try c.decodeIfPresent(Bool.self, forKey: .thermalCutoutEnabled) ?? d.thermalCutoutEnabled
        thermalThresholdCelsius = try c.decodeIfPresent(Double.self, forKey: .thermalThresholdCelsius) ?? d.thermalThresholdCelsius
        lowBatteryCutoutEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowBatteryCutoutEnabled) ?? d.lowBatteryCutoutEnabled
        lowBatteryThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .lowBatteryThresholdPercent) ?? d.lowBatteryThresholdPercent
        idleReleaseEnabled = try c.decodeIfPresent(Bool.self, forKey: .idleReleaseEnabled) ?? d.idleReleaseEnabled
        idleReleaseMinutes = try c.decodeIfPresent(Int.self, forKey: .idleReleaseMinutes) ?? d.idleReleaseMinutes
        processSniffingEnabled = try c.decodeIfPresent(Bool.self, forKey: .processSniffingEnabled) ?? d.processSniffingEnabled
        autoAcquireForKnownAgents = try c.decodeIfPresent(Bool.self, forKey: .autoAcquireForKnownAgents) ?? d.autoAcquireForKnownAgents
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
    }

    public static func load(from url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.configFilename)) -> AdrafinilSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AdrafinilSettings.self, from: data) else {
            return AdrafinilSettings()
        }
        return s
    }

    public func save(to url: URL = AdrafinilConstants.appSupportURL.appendingPathComponent(AdrafinilConstants.configFilename)) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
