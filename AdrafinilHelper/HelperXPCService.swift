import AdrafinilShared
import Foundation
import OSLog

final class HelperXPCService: NSObject, HelperXPCProtocol, @unchecked Sendable {
    /// The process-wide blocker, shared across every connection (see `SleepBlocker`). Internally
    /// synchronized, so this service needs no lock of its own.
    private let blocker: SleepBlocker
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "XPCService")

    init(blocker: SleepBlocker) {
        self.blocker = blocker
        super.init()
    }

    func setSleepBlocked(_ blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
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
    static let string = AdrafinilConstants.marketingVersion
}
