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
    /// Release a hook/sniffed hold once the agent's process tree has been CPU-idle this long. This is
    /// what catches an Esc-interrupt (no `Stop` hook fires), so it's tens of seconds, not minutes.
    public var idleReleaseSeconds: Int = 90

    public var processSniffingEnabled: Bool = true
    public var autoAcquireForKnownAgents: Bool = false

    /// Allow agents to place explicit, reasoned "keep awake" holds (via `adrafinil hold` or the
    /// MCP server). When false, hold requests are rejected, so only a live agent session — via its
    /// editor hooks — can keep the Mac awake.
    public var agentHoldsEnabled: Bool = true
    /// Hard cap, in hours, on how long a single agent hold can last. Any longer request is clamped
    /// down to this — a forgetful agent can never pin the Mac awake indefinitely.
    public var manualHoldMaxHours: Double = 4

    public var launchAtLogin: Bool = true
    public var showInMenuBar: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case soundOnLidClose
        case soundVolume
        case chimeName
        case lockOnLidClose
        case thermalCutoutEnabled
        case thermalThresholdCelsius
        case lowBatteryCutoutEnabled
        case lowBatteryThresholdPercent
        case idleReleaseEnabled
        case idleReleaseSeconds
        case processSniffingEnabled
        case autoAcquireForKnownAgents
        case agentHoldsEnabled
        case manualHoldMaxHours
        case launchAtLogin
        case showInMenuBar
    }

    /// Decode-only key for the retired `idleReleaseMinutes` field, migrated to `idleReleaseSeconds`.
    private enum LegacyCodingKeys: String, CodingKey {
        case idleReleaseMinutes
    }

    /// Resilient decoding: a missing OR type-mismatched key falls back to its default rather
    /// than throwing. Swift's synthesized decoder throws on any absent key — and
    /// `decodeIfPresent` throws on a wrong-typed one — either of which would make `load()`
    /// discard a user's *entire* config over a single bad field (a newer build's new setting,
    /// or a hand-edit like `"idleReleaseSeconds": "90"`). Decoding each field independently
    /// confines the damage to that field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdrafinilSettings()
        self.soundOnLidClose = (try? c.decodeIfPresent(Bool.self, forKey: .soundOnLidClose)) ?? d.soundOnLidClose
        self.soundVolume = (try? c.decodeIfPresent(Float.self, forKey: .soundVolume)) ?? d.soundVolume
        self.chimeName = (try? c.decodeIfPresent(String.self, forKey: .chimeName)) ?? d.chimeName
        self.lockOnLidClose = (try? c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose)) ?? d.lockOnLidClose
        self.thermalCutoutEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .thermalCutoutEnabled)) ?? d.thermalCutoutEnabled
        self.thermalThresholdCelsius = (try? c.decodeIfPresent(Double.self, forKey: .thermalThresholdCelsius)) ?? d.thermalThresholdCelsius
        self.lowBatteryCutoutEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .lowBatteryCutoutEnabled)) ?? d.lowBatteryCutoutEnabled
        self.lowBatteryThresholdPercent = (try? c.decodeIfPresent(Int.self, forKey: .lowBatteryThresholdPercent)) ?? d.lowBatteryThresholdPercent
        self.idleReleaseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .idleReleaseEnabled)) ?? d.idleReleaseEnabled
        // Prefer the seconds field; migrate a legacy `idleReleaseMinutes` (×60) if that's all that's
        // present; otherwise fall back to the default.
        if let secs = try? c.decodeIfPresent(Int.self, forKey: .idleReleaseSeconds) {
            self.idleReleaseSeconds = secs
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let mins = try? legacy.decodeIfPresent(Int.self, forKey: .idleReleaseMinutes) {
            self.idleReleaseSeconds = mins * 60
        } else {
            self.idleReleaseSeconds = d.idleReleaseSeconds
        }
        self.processSniffingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .processSniffingEnabled)) ?? d.processSniffingEnabled
        self.autoAcquireForKnownAgents = (try? c.decodeIfPresent(Bool.self, forKey: .autoAcquireForKnownAgents)) ?? d.autoAcquireForKnownAgents
        self.agentHoldsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .agentHoldsEnabled)) ?? d.agentHoldsEnabled
        self.manualHoldMaxHours = (try? c.decodeIfPresent(Double.self, forKey: .manualHoldMaxHours)) ?? d.manualHoldMaxHours
        self.launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        self.showInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showInMenuBar)) ?? d.showInMenuBar
        clampToSupportedRanges()
    }

    /// Clamps the numeric fields into ranges where the policies stay sane. The UI enforces
    /// tighter bounds; config.json is hand-editable, and e.g. a battery threshold of 150 would
    /// make the cutout fire on every tick, while a thermal threshold of 0 would never not fire.
    /// Non-finite values reset to defaults before clamping.
    private mutating func clampToSupportedRanges() {
        let d = AdrafinilSettings()
        if !soundVolume.isFinite { soundVolume = d.soundVolume }
        if !thermalThresholdCelsius.isFinite { thermalThresholdCelsius = d.thermalThresholdCelsius }
        if !manualHoldMaxHours.isFinite { manualHoldMaxHours = d.manualHoldMaxHours }
        soundVolume = min(max(soundVolume, 0), 1)
        thermalThresholdCelsius = min(max(thermalThresholdCelsius, 50), 105)
        lowBatteryThresholdPercent = min(max(lowBatteryThresholdPercent, 1), 99)
        idleReleaseSeconds = min(max(idleReleaseSeconds, 30), 3_600)
        manualHoldMaxHours = min(max(manualHoldMaxHours, 0.25), 24)
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
