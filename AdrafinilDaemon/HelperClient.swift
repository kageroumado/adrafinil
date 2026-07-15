import AdrafinilShared
import Foundation
import OSLog

@MainActor
final class HelperClient {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "HelperClient")
    private var connection: NSXPCConnection?
    private(set) var isConnected: Bool = false
    private var desiredBlockedState: Bool = false
    private var leaseCapability = HelperLeaseCapability()
    var onApplyFailure: (() -> Void)?
    var onLeaseCapabilityRecovered: (() -> Void)?

    var leaseFailureLatched: Bool {
        leaseCapability.failureLatched
    }

    /// True while the last attempt to apply the desired state failed (pmset error, timeout,
    /// helper unreachable). Surfaced in `DaemonStatus.warnings`: the user may be about to close
    /// the lid trusting a block that isn't fully in place.
    private(set) var lastApplyFailed: Bool = false

    private var capabilityProbeTask: Task<Void, Never>?
    private static let maxBackoff: Double = 30

    /// Bound on one helper round-trip. The helper's `set` shells out to `pmset` (itself bounded
    /// by a watchdog); a reply that takes longer than this means a wedged helper, and the serial
    /// blocking-drive loop must not hang on it forever — every later block-state flip would queue
    /// behind the hang, unapplied.
    private static let callTimeout: Double = 15
    static let leaseDuration: Double = 15

    private enum CallOutcome {
        case applied(Bool)
        case failed
        case timedOut
    }

    func setBlocked(_ blocked: Bool, requiresIdleAssertion: Bool = true) async {
        desiredBlockedState = blocked
        let conn = ensureConnection()
        let outcome = await sendSetBlocked(
            blocked,
            requiresIdleAssertion: requiresIdleAssertion,
            over: conn
        )

        switch outcome {
        case let .applied(actual) where actual == blocked:
            if blocked {
                _ = await renewBlockLease()
            } else {
                leaseCapability.recordUnblocked()
                lastApplyFailed = leaseCapability.failureLatched
            }
        case let .applied(actual):
            // The helper answered but couldn't reach the requested state (e.g. `pmset` failed,
            // leaving idle-only protection). Fail closed instead of repeatedly forking `pmset`.
            log.error("Helper applied \(actual) but \(blocked) was requested — failing closed")
            markProtectionFailure()
        case .failed:
            markProtectionFailure()
        case .timedOut:
            // Tear the connection down: launchd respawns a crashed helper on the next call, and
            // a wedged-but-alive one gets a fresh connection once it recovers.
            log.error("Helper setSleepBlocked timed out after \(Self.callTimeout)s — invalidating connection")
            markProtectionFailure()
            dropConnection()
        }
    }

    /// Renews the helper's short crash-safety lease. Any failure immediately marks protection
    /// unavailable; recovery probes the lease selector without reapplying the privileged block.
    @discardableResult
    func renewBlockLease() async -> Bool {
        guard desiredBlockedState else { return false }
        let outcome = await sendRenewLease(over: ensureConnection())
        switch outcome {
        case .applied(true):
            let recovered = leaseCapability.failureLatched
            leaseCapability.recordRenewalSuccess(isActive: true)
            lastApplyFailed = false
            capabilityProbeTask?.cancel()
            capabilityProbeTask = nil
            if recovered {
                onLeaseCapabilityRecovered?()
            }
            return leaseCapability.allowsBlocking
        case .failed, .applied(false), .timedOut:
            markProtectionFailure()
            if case .timedOut = outcome {
                dropConnection()
            }
            scheduleCapabilityProbe()
            return false
        }
    }

    private func sendSetBlocked(
        _ blocked: Bool,
        requiresIdleAssertion: Bool,
        over conn: NSXPCConnection
    ) async -> CallOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<CallOutcome, Never>) in
            // Resume exactly once: the timeout arm, the error handler, and the reply all race —
            // whichever fires first wins, and a double resume would trap the continuation.
            let once = OnceResumer<CallOutcome> { cont.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout) {
                once.resume(.timedOut)
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.log.error("Helper proxy error: \(error.localizedDescription)")
                once.resume(.failed)
            }) as? HelperXPCProtocol else {
                once.resume(.failed)
                return
            }
            proxy.setSleepBlocked(blocked, requiresIdleAssertion: requiresIdleAssertion) { [weak self] applied, error in
                if let error {
                    self?.log.error("Helper setSleepBlocked error: \(error.localizedDescription)")
                    once.resume(.failed)
                } else {
                    self?.log.info("Helper applied blocked=\(applied)")
                    once.resume(.applied(applied))
                }
            }
        }
    }

    private func sendRenewLease(over conn: NSXPCConnection) async -> CallOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<CallOutcome, Never>) in
            let once = OnceResumer<CallOutcome> { cont.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout) {
                once.resume(.timedOut)
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.log.error("Helper lease proxy error: \(error.localizedDescription)")
                once.resume(.failed)
            }) as? HelperXPCProtocol else {
                once.resume(.failed)
                return
            }
            proxy.renewSleepBlockLease(seconds: Self.leaseDuration) { active in
                once.resume(.applied(active))
            }
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection {
            return c
        }
        let c = NSXPCConnection(machServiceName: AdrafinilConstants.helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        // Handlers are bound to THIS connection: an event arriving late from an abandoned
        // connection must not tear down its healthy replacement.
        c.invalidationHandler = { [weak self, weak c] in
            Task { @MainActor in self?.handleConnectionDeath(of: c, kind: "invalidated (helper crashed or was terminated)") }
        }
        c.interruptionHandler = { [weak self, weak c] in
            Task { @MainActor in self?.handleConnectionDeath(of: c, kind: "interrupted") }
        }
        c.resume()
        connection = c
        isConnected = true
        return c
    }

    private func handleConnectionDeath(of dead: NSXPCConnection?, kind: String) {
        guard dead === connection else { return }
        log.warning("Helper XPC \(kind)")
        dropConnection()
        // Never trust an unleased block across a helper death. The daemon force-releases once;
        // lightweight lease probes can prove a replacement helper without invoking `pmset`.
        if desiredBlockedState {
            markProtectionFailure()
            scheduleCapabilityProbe()
        }
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        isConnected = false
        old?.invalidate()
    }

    private func markProtectionFailure() {
        lastApplyFailed = true
        if leaseCapability.recordRenewalFailure() { onApplyFailure?() }
    }

    /// Recovery probes only the lease selector; they never call `setSleepBlocked` and therefore
    /// cannot repeatedly fork `pmset` against an old or wedged helper. Any reply proves the helper
    /// understands renewable leases; an inactive reply is expected after fail-closed unblocking.
    private func scheduleCapabilityProbe() {
        guard capabilityProbeTask == nil else { return }
        capabilityProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = 0
            while leaseCapability.failureLatched {
                let delay = min(pow(2.0, Double(attempt)), Self.maxBackoff)
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, leaseCapability.failureLatched else { break }
                switch await sendRenewLease(over: ensureConnection()) {
                case .applied(false):
                    leaseCapability.recordRenewalSuccess(isActive: false)
                    lastApplyFailed = false
                    onLeaseCapabilityRecovered?()
                case .applied(true):
                    // The selector exists, but the failed-closed unblock has not taken effect yet.
                    // Stop renewing long enough for the short lease to expire instead of repeatedly
                    // invoking privileged `pmset` or accidentally keeping the stale block alive.
                    try? await Task.sleep(for: .seconds(Self.leaseDuration + 1))
                case .timedOut:
                    dropConnection()
                case .failed:
                    break
                }
            }
            capabilityProbeTask = nil
        }
    }

    /// One-shot version probe, logged at startup, so version skew — an old helper still resident
    /// after an app update (launchd keeps the registered binary running) — shows up in the log
    /// instead of only as mysteriously failing calls.
    func logHelperVersion() {
        let conn = ensureConnection()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperXPCProtocol else { return }
        proxy.version { [log] version in
            if version == AdrafinilConstants.marketingVersion {
                log.info("Helper version \(version, privacy: .public)")
            } else {
                log.warning("Helper version \(version, privacy: .public) ≠ daemon \(AdrafinilConstants.marketingVersion, privacy: .public) — an old helper may still be resident")
            }
        }
    }
}
