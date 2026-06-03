import AdrafinilShared
import Foundation
import OSLog

/// Locks the screen immediately, used when the lid closes while an agent is active so the
/// kept-awake machine is still physically secured.
///
/// Uses the private `SACLockScreenImmediate()` from `login.framework` — the same primitive the
/// system uses for "Lock Screen". It is **explicit**, so it locks even when another app holds an
/// idle-lock-prevention assertion (e.g. a caffeinate-style tool), unlike the implicit lock that
/// rides on display/system sleep. The symbol lives in the dyld shared cache (no header, the
/// on-disk framework is a stub), so it is bound at runtime via `dlsym`. If that ever fails, falls
/// back to `pmset displaysleepnow`, which locks per the user's "require password" setting.
@MainActor
final class ScreenLocker {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "ScreenLocker")

    private typealias LockFunction = @convention(c) () -> Void
    private let lockFunction: LockFunction?

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            self.lockFunction = unsafeBitCast(symbol, to: LockFunction.self)
        } else {
            self.lockFunction = nil
            log.warning("SACLockScreenImmediate unavailable — will fall back to pmset displaysleepnow")
        }
    }

    func lock() {
        if let lockFunction {
            log.notice("locking screen via SACLockScreenImmediate")
            lockFunction()
        } else {
            log.notice("locking screen via pmset displaysleepnow (fallback)")
            displaySleepNow()
        }
    }

    private func displaySleepNow() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
        } catch {
            log.error("pmset displaysleepnow failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
