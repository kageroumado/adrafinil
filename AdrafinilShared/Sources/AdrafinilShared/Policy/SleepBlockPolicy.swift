import Foundation

/// Holds and releases the idle-system-sleep assertion — the standard, reference-counted
/// `IOPMAssertion` (`kIOPMAssertPreventUserIdleSystemSleep`). Stateful: it tracks whether the
/// assertion is currently held, so a repeated `acquire()` is a no-op.
public protocol IdleSleepAsserting: AnyObject {
    var isHeld: Bool { get }
    func acquire()
    func release()
}

/// Applies and clears the global clamshell-sleep block — the `SleepDisabled` power setting
/// (`pmset -a disablesleep`). Throwing because the underlying mechanism can fail.
public protocol ClamshellSleepControlling: AnyObject {
    func setDisabled(_ disabled: Bool) throws
}

/// The compose / idempotence / crash-recovery logic for keeping the Mac awake, independent of the
/// concrete IOKit and `pmset` mechanisms (which live behind `IdleSleepAsserting` and
/// `ClamshellSleepControlling`). This is the policy worth testing; the conformers are the
/// untestable API boundary.
///
/// On construction it clears any stale clamshell block left by a prior — possibly crashed —
/// instance: `disablesleep` persists across process death and reboot until explicitly cleared.
///
/// `set(blocked:)` is deliberately **not** short-circuited on an unchanged value: a repeated
/// `set(true)` re-asserts the clamshell block, which the daemon relies on to recover after a
/// sleep/wake transition. Every step is idempotent. An error applying the block propagates (the
/// XPC layer surfaces it); an error *clearing* the block on unblock is swallowed (best-effort —
/// the conformer logs its own failure), matching the original `SleepBlocker` behavior.
public final class SleepBlockPolicy {
    public private(set) var isBlocked = false

    private let idle: IdleSleepAsserting
    private let clamshell: ClamshellSleepControlling

    public init(idle: IdleSleepAsserting, clamshell: ClamshellSleepControlling) {
        self.idle = idle
        self.clamshell = clamshell
        // Crash recovery: clear any stale clamshell block from a prior instance.
        try? clamshell.setDisabled(false)
    }

    public func set(blocked: Bool) throws {
        if blocked {
            // Keep the idle assertion even if the clamshell block throws: partial protection (idle
            // sleep still blocked) serves the app's purpose better than rolling back to none, and the
            // daemon re-issues `set(true)` on its next reconcile — every step is idempotent, so the
            // clamshell block is retried while the idle assertion stays continuously held. The error
            // propagates so the daemon knows the block isn't yet complete.
            idle.acquire()
            try clamshell.setDisabled(true)
        } else {
            idle.release()
            try? clamshell.setDisabled(false)
        }
        isBlocked = blocked
    }
}
