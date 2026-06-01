import Foundation
import IOKit.ps
import AdrafinilShared
import OSLog

/// Polls battery charge and power source; triggers a cutout when, on battery with the lid closed
/// and an agent active, the charge falls to/under the threshold — so a kept-awake Mac sleeps
/// normally instead of draining to a hard shutdown in a bag. The battery sibling of
/// `ThermalMonitor`; the gate lives in `LowBatteryCutoutEvaluator` (AdrafinilShared, unit-tested).
@MainActor
final class BatteryMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "BatteryMonitor")

    var enabled: Bool = true
    var thresholdPercent: Int = 20
    var lidClosed: Bool = false
    /// Whether any assertion is currently held — the cutout only fires while we are keeping the
    /// Mac awake (with zero assertions there is nothing to cut out).
    var isBlocking: Bool = false
    var onCutout: (() -> Void)?
    /// Fired on every successful reading: `(percent, onBattery)`.
    var onReading: ((Int, Bool) -> Void)?

    private(set) var lastPercent: Int?
    private(set) var lastOnBattery: Bool = false

    private let evaluator = LowBatteryCutoutEvaluator()
    private var runLoopSource: CFRunLoopSource?

    func start() {
        tick()  // seed an initial reading
        // Event-driven instead of polled: IOKit fires this source whenever power-source info changes
        // (plug/unplug, charge level), so there are no wakeups while nothing changes — and on AC at
        // full charge it is completely silent. The callback lands on the main run loop, which is the
        // daemon's main thread (= the main actor), so `assumeIsolated` is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.tick() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            log.error("Failed to create power-source notification source — battery cutout disabled")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    private func tick() {
        // Read every tick so the daemon can surface a current charge; the cutout is gated below.
        guard let reading = Self.read() else { return }
        lastPercent = reading.percent
        lastOnBattery = reading.onBattery
        onReading?(reading.percent, reading.onBattery)

        guard evaluator.shouldCutout(
            batteryPercent: reading.percent,
            thresholdPercent: thresholdPercent,
            onBattery: reading.onBattery,
            enabled: enabled,
            lidClosed: lidClosed,
            isBlocking: isBlocking
        ) else { return }
        log.warning("Low-battery cutout: \(reading.percent)% <= \(self.thresholdPercent)% on battery")
        onCutout?()
    }

    /// Reads the internal battery as `(percent 0–100, onBattery)`. Returns nil when there is no
    /// internal battery (desktop) or the power-source info is unavailable.
    private static func read() -> (percent: Int, onBattery: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0 else {
                continue
            }
            let percent = Int((Double(current) / Double(maxCap) * 100).rounded())
            let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (percent, onBattery)
        }
        return nil
    }
}
