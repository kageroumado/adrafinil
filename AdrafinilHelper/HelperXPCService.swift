import Foundation
import AdrafinilShared

final class HelperXPCService: NSObject, HelperXPCProtocol, @unchecked Sendable {
    private let blocker = SleepBlocker()
    private let lock = NSLock()

    func setSleepBlocked(_ blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            try blocker.set(blocked: blocked)
            reply(blocker.isBlocked, nil)
        } catch {
            reply(blocker.isBlocked, error as NSError)
        }
    }

    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void) {
        reply(blocker.isBlocked)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperVersion.string)
    }
}

enum HelperVersion {
    static let string = "0.1.0"
}
