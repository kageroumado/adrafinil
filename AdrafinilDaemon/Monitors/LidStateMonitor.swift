import AdrafinilShared
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Observes the lid open/closed state via IOKit "AppleClamshellState" registry property.
@MainActor
final class LidStateMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "LidMonitor")
    private(set) var isLidClosed: Bool = false

    /// Called whenever the lid state changes. Parameter: new closed state.
    var onChange: ((Bool) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootDomain: io_registry_entry_t = 0

    init() {
        start()
    }

    func start() {
        // Use service matching rather than a hardcoded registry path: the
        // "IOService:/IOResources/IOPMrootDomain" path does not resolve on macOS 26.3
        // (returns 0). `IOServiceGetMatchingService(…"IOPMrootDomain")` is the same lookup the
        // helper's SleepBlocker uses and resolves reliably.
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            log.warning("Could not get IOPMrootDomain")
            return
        }
        updateLidState()
        registerNotification()
    }

    private func updateLidState() {
        guard rootDomain != 0 else { return }
        let propRaw = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        let closed = (propRaw?.takeRetainedValue() as? Bool) ?? false
        if closed != isLidClosed {
            log.notice("lid \(closed ? "CLOSED" : "OPENED", privacy: .public)")
            isLidClosed = closed
            onChange?(closed)
        }
    }

    private func registerNotification() {
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notificationPort else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                let monitor = Unmanaged<LidStateMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.updateLidState() }
            },
            context,
            &notifier,
        )
        if result != KERN_SUCCESS {
            log.warning("IOServiceAddInterestNotification failed: \(result)")
        }
    }

    isolated deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let port = notificationPort { IONotificationPortDestroy(port) }
    }
}
