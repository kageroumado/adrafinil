import Foundation

/// Decides whether the thermal cutout should fire. Pure.
///
/// The cutout force-releases all assertions so a bag-bound, lid-closed Mac can't cook itself. It
/// fires **only** while Adrafinil is actively keeping the Mac awake with the lid closed — lid-open
/// thermals are macOS's problem, and with zero assertions there is nothing to cut out.
public struct ThermalCutoutEvaluator {
    public init() {}

    public func shouldCutout(
        temperatureCelsius: Double,
        thresholdCelsius: Double,
        enabled: Bool,
        lidClosed: Bool,
        isBlocking: Bool
    ) -> Bool {
        guard enabled, lidClosed, isBlocking else { return false }
        return temperatureCelsius >= thresholdCelsius
    }
}
