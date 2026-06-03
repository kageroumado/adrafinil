import AdrafinilShared
import Foundation
import OSLog

/// Polls CPU temperature via SMC; triggers a cutout if the user-configured threshold is
/// exceeded *while the lid is closed*. Lid-open thermals are macOS's problem, not ours.
@MainActor
final class ThermalMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "ThermalMonitor")

    var enabled: Bool = true
    var thresholdCelsius: Double = 80.0
    var lidClosed: Bool = false
    /// Whether any assertion is currently held. The cutout only fires while we are actively keeping
    /// the Mac awake — with zero assertions there is nothing to cut out — so this also gates the
    /// poll itself: the 15s SMC read runs only while blocking, leaving the daemon idle (no periodic
    /// CPU wakeups) for the vast majority of its life when no agent is active.
    var isBlocking: Bool = false {
        didSet {
            guard isBlocking != oldValue else { return }
            if isBlocking { startPolling() } else { stopPolling() }
        }
    }
    var onCutout: (() -> Void)?
    /// Fired on every successful reading (used by the daemon to track peak temp while closed).
    var onReading: ((Double) -> Void)?

    private(set) var lastReadingCelsius: Double?

    private let smc = SMCReader()
    private var timer: Timer?

    func start() {
        _ = smc.open()
        // No polling until something is blocking — `isBlocking`'s didSet arms/disarms the timer.
        if isBlocking { startPolling() }
    }

    /// One-shot read for callers that want a current temperature while the poll is stopped (e.g. the
    /// popover asking for a value when no agent is active). Refreshes the cache as a side effect.
    func readNow() -> Double? {
        guard let temp = smc.readCPUTemperature() else { return lastReadingCelsius }
        lastReadingCelsius = temp
        return temp
    }

    private func startPolling() {
        guard timer == nil else { return }
        tick() // seed a fresh reading immediately when blocking begins
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Read on each tick while blocking; the cutout itself is gated below.
        guard let temp = smc.readCPUTemperature() else { return }
        lastReadingCelsius = temp
        onReading?(temp)

        // Only cut out while we are actively keeping the Mac awake with the lid closed (the gate
        // lives in AdrafinilShared, where it is unit-tested).
        guard ThermalCutoutEvaluator().shouldCutout(
            temperatureCelsius: temp,
            thresholdCelsius: thresholdCelsius,
            enabled: enabled,
            lidClosed: lidClosed,
            isBlocking: isBlocking,
        ) else { return }
        log.warning("Thermal cutout: \(temp)°C >= \(self.thresholdCelsius)°C")
        onCutout?()
    }
}
