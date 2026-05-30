import Foundation

/// Decides whether the low-battery cutout should fire. Pure.
///
/// The sibling of `ThermalCutoutEvaluator`: where thermal protects a kept-awake, lid-closed Mac
/// from cooking itself, this protects it from silently draining to a hard shutdown in a bag. It
/// fires **only** on battery power while Adrafinil is actively keeping the Mac awake with the lid
/// closed — on AC there is no drain risk, lid-open is the user's problem, and with zero assertions
/// there is nothing to cut out. On crossing, the daemon force-releases all assertions so normal
/// low-power sleep can take over before the charge is gone.
public struct LowBatteryCutoutEvaluator {
    public init() {}

    public func shouldCutout(
        batteryPercent: Int,
        thresholdPercent: Int,
        onBattery: Bool,
        enabled: Bool,
        lidClosed: Bool,
        isBlocking: Bool
    ) -> Bool {
        guard enabled, onBattery, lidClosed, isBlocking else { return false }
        return batteryPercent <= thresholdPercent
    }
}
