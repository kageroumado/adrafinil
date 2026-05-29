import Foundation
import OSLog
import AdrafinilShared

final class HelperXPCService: NSObject, HelperXPCProtocol, @unchecked Sendable {
    private let blocker = SleepBlocker()
    private let lock = NSLock()
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "XPCService")

    func setSleepBlocked(_ blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        log.notice("XPC setSleepBlocked(\(blocked, privacy: .public)) received from daemon")
        do {
            try blocker.set(blocked: blocked)
            reply(blocker.isBlocked, nil)
        } catch {
            log.error("XPC setSleepBlocked(\(blocked, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            reply(blocker.isBlocked, error as NSError)
        }
    }

    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void) {
        log.debug("XPC sleepBlockedState query -> \(self.blocker.isBlocked, privacy: .public)")
        reply(blocker.isBlocked)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperVersion.string)
    }
}

enum HelperVersion {
    static let string = "0.1.0"
}
