import Foundation
import AdrafinilShared
import OSLog

/// Polls CPU temperature via SMC; triggers a cutout if the user-configured threshold is
/// exceeded *while the lid is closed*. Lid-open thermals are macOS's problem, not ours.
@MainActor
final class ThermalMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "ThermalMonitor")

    var enabled: Bool = true
    var thresholdCelsius: Double = 80.0
    var lidClosed: Bool = false
    /// Whether any assertion is currently held. The cutout only fires while we are actively
    /// keeping the Mac awake — with zero assertions there is nothing to cut out.
    var isBlocking: Bool = false
    var onCutout: (() -> Void)?
    /// Fired on every successful reading (used by the daemon to track peak temp while closed).
    var onReading: ((Double) -> Void)?

    private(set) var lastReadingCelsius: Double?

    private let smc = SMCReader()
    private var timer: Timer?

    /// CPU proximity sensor. Reliable across Intel and Apple Silicon.
    private let sensorKey = "TC0P"

    func start() {
        _ = smc.open()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // Read every tick so the menu-bar popover can always show a current temperature;
        // SMC reads are cheap. The cutout itself is gated below.
        guard let temp = smc.readTemperature(key: sensorKey) else { return }
        lastReadingCelsius = temp
        onReading?(temp)

        // Only cut out while we are actively keeping the Mac awake with the lid closed (the gate
        // lives in AdrafinilShared, where it is unit-tested).
        guard ThermalCutoutEvaluator().shouldCutout(
            temperatureCelsius: temp,
            thresholdCelsius: thresholdCelsius,
            enabled: enabled,
            lidClosed: lidClosed,
            isBlocking: isBlocking
        ) else { return }
        log.warning("Thermal cutout: \(temp)°C >= \(self.thresholdCelsius)°C")
        onCutout?()
    }
}
