import Foundation

/// XPC interface exposed by AdrafinilHelper. Single-purpose: toggle sleep blocking.
/// Reply closures are `@Sendable`: NSXPC delivers them on its own private queue, so they
/// must not be `@MainActor`-isolated (which would trap when the reply fires off the main actor).
@objc
public protocol HelperXPCProtocol {
    /// Block (true) or unblock (false) system sleep, including clamshell sleep.
    /// Idempotent. Returns the actual resulting state.
    func setSleepBlocked(_ blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void)

    /// Current sleep-blocking state as seen by the helper.
    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void)

    /// Helper version string.
    func version(reply: @escaping @Sendable (String) -> Void)
}
