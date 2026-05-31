import Foundation
import IOKit
import IOKit.ps

/// What the host Mac physically has, so the UI can hide laptop-only features on a desktop
/// (Mac Studio, Mac mini, Mac Pro, iMac). The *core* keep-awake works on any Mac — macOS idle-sleep
/// is driven by input inactivity, not CPU load, so a desktop left running an agent task will sleep
/// and stall it just like a laptop. Only the lid and battery layers (sound/lock on lid close, the
/// low-battery cutout, the "while you were away" recap) are portable-only.
public struct DeviceCapabilities: Sendable, Equatable {
    public let hasLid: Bool
    public let hasBattery: Bool

    /// A desktop Mac: nothing to close, nothing to drain. Both signals must be absent — a laptop
    /// always has a battery, so even if the lid probe transiently misses we won't mislabel it.
    public var isDesktop: Bool { !hasLid && !hasBattery }

    public init(hasLid: Bool, hasBattery: Bool) {
        self.hasLid = hasLid
        self.hasBattery = hasBattery
    }

    /// Probes the host. Cached as a `static let` since hardware doesn't change within a run.
    public static let current = DeviceCapabilities(hasLid: detectLid(), hasBattery: detectBattery())

    /// A lid exists iff `IOPMrootDomain` publishes `AppleClamshellState` (portables do; desktops
    /// don't). Same property `LidStateMonitor` reads.
    private static func detectLid() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() != nil
    }

    /// An internal battery exists iff a power source of type `InternalBattery` is present. Same
    /// probe `BatteryMonitor` uses (which returns nil — "no battery (desktop)" — otherwise).
    private static func detectBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
            else { return false }
            return (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }
}
