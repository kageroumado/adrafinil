import Foundation
import AdrafinilShared
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Observes system sleep/wake transitions via `IORegisterForSystemPower`.
///
/// The helper's private clamshell-disable bit can be reset by the kernel across a
/// sleep/wake cycle (see `SleepBlocker`), so the daemon re-applies the current
/// blocking state to the helper when the system finishes waking.
@MainActor
final class SystemPowerMonitor {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "PowerMonitor")

    /// Called when the system has finished waking from sleep.
    var onWake: (() -> Void)?

    // `kIOMessage*` from <IOKit/IOMessage.h>. They are function-like-macro values
    // (`iokit_common_msg(m)` == `0xE000_0000 | m`) that don't import into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?

    init() {
        start()
    }

    private func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notificationPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(messageType, argument: messageArgument) }
            },
            &notifier
        )

        guard rootPort != 0, let port = notificationPort else {
            log.warning("IORegisterForSystemPower failed — wake re-assertion disabled")
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    }

    private func handle(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep, Self.systemWillSleep:
            // We never veto sleep — acknowledge at once so we don't delay it.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake?()
        default:
            break
        }
    }

    isolated deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let port = notificationPort { IONotificationPortDestroy(port) }
    }
}
