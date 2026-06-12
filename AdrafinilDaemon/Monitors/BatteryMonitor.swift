import AdrafinilShared
import Foundation
import IOKit.ps
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
    /// Re-evaluate the cutout whenever the lid state changes. A lid close is **not** a power-source
    /// event, so without this the IOKit power-source notification (which fires only on
    /// plug/unplug/charge changes) would never re-check — and the cutout would miss its single most
    /// important trigger: closing the lid while *already* on battery below the threshold, i.e. the
    /// drain-to-shutdown-in-a-bag case this whole monitor exists to prevent.
    var lidClosed: Bool = false {
        didSet { if lidClosed != oldValue { gateChanged() } }
    }

    /// Whether any assertion is currently held — the cutout only fires while we are keeping the Mac
    /// awake (with zero assertions there is nothing to cut out). Re-evaluates on change so a hold
    /// acquired while already on battery with the lid closed is checked immediately, not only on the
    /// next power-source event.
    var isBlocking: Bool = false {
        didSet { if isBlocking != oldValue { gateChanged() } }
    }

    var onCutout: (() -> Void)?
    /// Fired on every successful reading: `(percent, onBattery)`.
    var onReading: ((Int, Bool) -> Void)?

    private(set) var lastPercent: Int?
    private(set) var lastOnBattery: Bool = false

    private let evaluator = LowBatteryCutoutEvaluator()
    private var runLoopSource: CFRunLoopSource?
    /// Safety-net poll, armed only while blocking with the lid closed. The IOKit power-source
    /// notification catches plug/unplug and charge changes, but those events can be coalesced or
    /// throttled while the display is asleep — so the slow drain that matters most (agent working,
    /// lid shut, battery falling toward the threshold) could otherwise cross the line unnoticed until
    /// the next event. Polling closes that gap. It costs nothing extra: the Mac is already awake
    /// (we're holding a wake assertion) exactly when this runs, and it disarms the instant the hold is
    /// released or the lid opens, so there are no wakeups while idle.
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 60

    func start() {
        tick() // seed an initial reading
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
            log.error("Failed to create power-source notification source — battery cutout relies on the lid/blocking poll only")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    isolated deinit {
        pollTimer?.invalidate()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// A lid or blocking change: re-evaluate immediately on the edge, then arm/disarm the safety-net
    /// poll for the new state.
    private func gateChanged() {
        tick()
        updatePollTimer()
    }

    /// Poll only while blocking *and* the lid is closed — the one window where a slow drain can cross
    /// the threshold unseen. Disarmed otherwise so an open-lid or idle daemon never wakes on a timer.
    private func updatePollTimer() {
        let shouldPoll = isBlocking && lidClosed
        if shouldPoll, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !shouldPoll, pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
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
            isBlocking: isBlocking,
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
