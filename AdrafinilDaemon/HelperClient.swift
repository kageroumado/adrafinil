import AdrafinilShared
import Foundation
import OSLog

@MainActor
final class HelperClient {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "HelperClient")
    private var connection: NSXPCConnection?
    private(set) var isConnected: Bool = false
    private var desiredBlockedState: Bool = false

    /// True while the last attempt to apply the desired state failed (pmset error, timeout,
    /// helper unreachable). Surfaced in `DaemonStatus.warnings`: the user may be about to close
    /// the lid trusting a block that isn't fully in place.
    private(set) var lastApplyFailed: Bool = false

    /// Reconnect backoff. A helper that crashes on launch would otherwise be relaunched in a tight
    /// loop (each invalidation immediately reapplies, which respawns it). Back off exponentially,
    /// capped, and reset once a call succeeds.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private static let maxBackoff: Double = 30

    /// Bound on one helper round-trip. The helper's `set` shells out to `pmset` (itself bounded
    /// by a watchdog); a reply that takes longer than this means a wedged helper, and the serial
    /// blocking-drive loop must not hang on it forever — every later block-state flip would queue
    /// behind the hang, unapplied.
    private static let callTimeout: Double = 15

    private enum CallOutcome {
        case applied(Bool)
        case failed
        case timedOut
    }

    func setBlocked(_ blocked: Bool) async {
        desiredBlockedState = blocked
        let conn = ensureConnection()
        let outcome = await sendSetBlocked(blocked, over: conn)

        switch outcome {
        case let .applied(actual) where actual == blocked:
            reconnectAttempts = 0
            lastApplyFailed = false
        case let .applied(actual):
            lastApplyFailed = true
            // The helper answered but couldn't reach the requested state (e.g. `pmset` failed,
            // leaving idle-only protection). Retry with backoff rather than trusting a partial
            // block until the next edge.
            log.error("Helper applied \(actual) but \(blocked) was requested — scheduling reapply")
            scheduleReapplyIfNeeded()
        case .failed:
            lastApplyFailed = true
            scheduleReapplyIfNeeded()
        case .timedOut:
            lastApplyFailed = true
            // Tear the connection down: launchd respawns a crashed helper on the next call, and
            // a wedged-but-alive one gets a fresh connection once it recovers.
            log.error("Helper setSleepBlocked timed out after \(Self.callTimeout)s — invalidating connection")
            dropConnection()
            scheduleReapplyIfNeeded()
        }
    }

    private func sendSetBlocked(_ blocked: Bool, over conn: NSXPCConnection) async -> CallOutcome {
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
            proxy.setSleepBlocked(blocked) { [weak self] applied, error in
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

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
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
        // A crash while sleep was blocked is the worst case: respawn the helper
        // (the next setBlocked recreates the connection, which relaunches it via launchd; the
        // helper resets disablesleep to 0 on init) and reapply the desired state. Only bother
        // if we actually want sleep blocked — if we wanted it allowed, a dead helper already
        // means sleep is allowed, so there's nothing to reapply.
        scheduleReapplyIfNeeded()
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        isConnected = false
        old?.invalidate()
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

    /// Reapplies the desired blocked state after a backoff, so a helper that fails to launch is
    /// retried with widening gaps (1, 2, 4, … capped) instead of in a tight respawn loop.
    private func scheduleReapplyIfNeeded() {
        guard desiredBlockedState else { return }
        reconnectTask?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempts)), Self.maxBackoff)
        reconnectAttempts += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, desiredBlockedState else { return }
            await setBlocked(true)
        }
    }
}
