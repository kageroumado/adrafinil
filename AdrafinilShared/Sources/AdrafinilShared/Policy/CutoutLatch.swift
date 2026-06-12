import Foundation

/// Latches a fired safety cutout until its hazard has actually receded.
///
/// A cutout releases every assertion — but the agent that was pinning the Mac is usually still
/// running, and its very next hook event (or the sniff sweep) would re-acquire within seconds.
/// The monitors re-seed a reading the moment blocking resumes, so without a latch the system
/// oscillates: acquire → cutout → release → re-acquire…, each cycle burning more charge below
/// the threshold meant to protect it, or re-heating the Mac the cutout just saved. While
/// latched, the daemon rejects acquires.
///
/// Clearing requires the hazard to recede with margin (hysteresis), or the lid to open —
/// open-lid thermals and drain are macOS's problem, and a present user can re-close the lid to
/// re-arm protection deliberately.
public struct CutoutLatch: Equatable, Sendable {
    public enum Cause: String, Sendable, CaseIterable {
        case thermal
        case lowBattery
    }

    public static let thermalHysteresisCelsius = 5.0
    public static let batteryHysteresisPercent = 5

    public private(set) var active: Set<Cause> = []

    public init() {}

    public var isLatched: Bool {
        !active.isEmpty
    }

    public mutating func trip(_ cause: Cause) {
        active.insert(cause)
    }

    /// Re-evaluates the latch against current conditions; returns the causes that cleared.
    /// Unknown readings (`nil`) keep a latch held — a cutout must not clear on missing data.
    @discardableResult
    public mutating func update(
        temperatureCelsius: Double?,
        thermalThresholdCelsius: Double,
        batteryPercent: Int?,
        onBattery: Bool?,
        batteryThresholdPercent: Int,
        lidClosed: Bool,
    ) -> Set<Cause> {
        var cleared: Set<Cause> = []
        if active.contains(.thermal) {
            let cooled = temperatureCelsius.map { $0 <= thermalThresholdCelsius - Self.thermalHysteresisCelsius } ?? false
            if !lidClosed || cooled {
                active.remove(.thermal)
                cleared.insert(.thermal)
            }
        }
        if active.contains(.lowBattery) {
            let charged = batteryPercent.map { $0 >= batteryThresholdPercent + Self.batteryHysteresisPercent } ?? false
            if !lidClosed || onBattery == false || charged {
                active.remove(.lowBattery)
                cleared.insert(.lowBattery)
            }
        }
        return cleared
    }

    /// User-facing explanation for a rejected acquire.
    public var rejectionMessage: String? {
        guard isLatched else { return nil }
        if active.contains(.thermal), active.contains(.lowBattery) {
            return "Safety cutouts are active (overheating and low battery) — acquires are paused until conditions recover or the lid opens."
        }
        if active.contains(.thermal) {
            return "The thermal cutout fired — acquires are paused until the Mac cools down or the lid opens."
        }
        return "The low-battery cutout fired — acquires are paused until charging resumes or the lid opens."
    }
}
