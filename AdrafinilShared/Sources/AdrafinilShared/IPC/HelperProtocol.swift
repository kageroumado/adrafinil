import Foundation

/// XPC interface exposed by AdrafinilHelper. Single-purpose: toggle sleep blocking.
/// Reply closures are `@Sendable`: NSXPC delivers them on its own private queue, so they
/// must not be `@MainActor`-isolated (which would trap when the reply fires off the main actor).
@objc
public protocol HelperXPCProtocol {
    /// Block (true) or unblock (false) system sleep, including clamshell sleep. Observer-only
    /// Codex requests set `requiresIdleAssertion` false because Codex owns ordinary idle blocking.
    /// Idempotent. Returns the actual resulting state.
    func setSleepBlocked(
        _ blocked: Bool,
        requiresIdleAssertion: Bool,
        reply: @escaping @Sendable (Bool, NSError?) -> Void,
    )

    /// Extends the helper's crash-safety lease. Returns whether blocking is still active; a false
    /// result means the lease already expired and the daemon must reapply the block.
    func renewSleepBlockLease(seconds: Double, reply: @escaping @Sendable (Bool) -> Void)

    /// Current sleep-blocking state as seen by the helper.
    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void)

    /// Helper version string.
    func version(reply: @escaping @Sendable (String) -> Void)
}
