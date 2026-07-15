import AdrafinilShared
import Foundation
import OSLog

final class HelperXPCService: NSObject, HelperXPCProtocol, @unchecked Sendable {
    /// The process-wide blocker, shared across every connection (see `SleepBlocker`). Internally
    /// synchronized, so this service needs no lock of its own.
    private let blocker: SleepBlocker
    private let leaseController: SleepBlockLeaseController
    /// Launch-time binary identity, shared process-wide, used to adopt an in-place update.
    private let staleness: ExecutableStaleness
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "XPCService")

    init(blocker: SleepBlocker, leaseController: SleepBlockLeaseController, staleness: ExecutableStaleness) {
        self.blocker = blocker
        self.leaseController = leaseController
        self.staleness = staleness
        super.init()
    }

    func setSleepBlocked(
        _ blocked: Bool,
        requiresIdleAssertion: Bool,
        reply: @escaping @Sendable (Bool, NSError?) -> Void,
    ) {
        log.notice("XPC setSleepBlocked(\(blocked, privacy: .public)) received from daemon")
        do {
            try blocker.set(blocked: blocked, requiresIdleAssertion: requiresIdleAssertion)
            // Start the lease in the same helper call that creates the block, closing the crash
            // window before the daemon's first explicit renewal arrives.
            if blocked {
                _ = leaseController.renew(for: 15)
            }
            if !blocked {
                leaseController.clear()
            }
            reply(blocker.isBlocked, nil)
        } catch {
            log.error("XPC setSleepBlocked(\(blocked, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            reply(blocker.isBlocked, error as NSError)
        }
        // Unblocking returns us to idle — the safe point to adopt a binary an update swapped in.
        if !blocked {
            relaunchIfUpdated()
        }
    }

    func renewSleepBlockLease(seconds: Double, reply: @escaping @Sendable (Bool) -> Void) {
        // Bound caller input so a buggy or compromised same-signature daemon cannot create a
        // practically permanent privileged block with one renewal.
        let duration = min(max(seconds, 1), 30)
        reply(leaseController.renew(for: duration))
    }

    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void) {
        log.debug("XPC sleepBlockedState query -> \(self.blocker.isBlocked, privacy: .public)")
        reply(blocker.isBlocked)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperVersion.string)
        // The daemon probes the helper's version once at startup, so a freshly relaunched (post-
        // update) daemon reaches here — the trigger that adopts a new helper binary while idle.
        relaunchIfUpdated()
    }

    /// Adopts a binary that an in-place app update swapped onto disk by exiting so `launchd`
    /// (KeepAlive) relaunches the helper from the new image. Gated on **not** currently blocking,
    /// since exiting clears the sleep block; the blocked state is re-read at the last moment so a
    /// concurrent acquire can't be dropped. A no-op unless the on-disk binary actually changed.
    private func relaunchIfUpdated() {
        guard staleness.hasBeenReplaced(), !blocker.isBlocked else { return }
        log.notice("Helper binary replaced by an update — exiting so launchd relaunches the new helper")
        exit(0)
    }
}

enum HelperVersion {
    static let string = AdrafinilConstants.marketingVersion
}
