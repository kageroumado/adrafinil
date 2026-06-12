import AdrafinilShared
import Foundation
import os
import OSLog

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Listener")

    /// One process-wide blocker, shared by every connection's service. Keeping the sleep-blocking
    /// state here (not per `HelperXPCService`) means a daemon reconnect reuses the live assertion
    /// instead of orphaning it — see `SleepBlocker`.
    let blocker = SleepBlocker()

    /// Records the helper's on-disk binary at launch (this delegate is built once, at process
    /// start), so an in-place app update can be detected and adopted by relaunching — see
    /// `HelperXPCService`.
    let staleness = ExecutableStaleness()

    /// Live-connection count plus a generation counter that invalidates pending dead-man checks
    /// whenever the picture changes. Lock-guarded: connection handlers fire on XPC's queues.
    private let connectionState = OSAllocatedUnfairLock(initialState: (connections: 0, generation: 0))

    /// How long the helper stays blocked with no daemon connected before concluding the daemon
    /// is gone for good (SIGKILLed at logout, force-quit) and clearing the block itself. Long
    /// enough for a daemon crash + launchd relaunch + reconnect; short enough that a lid-closed
    /// Mac isn't pinned awake indefinitely by a block nobody owns.
    private static let deadManGrace: TimeInterval = 60

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept connections from binaries signed by us. The daemon is the only
        // legitimate caller in practice. (Verifier lives in AdrafinilShared so the
        // daemon's app-facing listener can reuse it.)
        guard CallerVerifier.isAuthorized(newConnection) else {
            log.error("rejected XPC connection (pid \(newConnection.processIdentifier, privacy: .public)) — caller failed code-signing check")
            return false
        }
        log.notice("accepted XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")

        connectionState.withLock {
            $0.connections += 1
            $0.generation += 1
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperXPCService(blocker: blocker, staleness: staleness)
        newConnection.invalidationHandler = { [weak self] in
            self?.log.notice("XPC connection invalidated")
            self?.connectionEnded()
        }
        newConnection.interruptionHandler = { [log] in log.notice("XPC connection interrupted") }
        newConnection.resume()
        return true
    }

    /// Dead-man switch: when the last daemon connection drops while sleep is blocked, and no new
    /// connection arrives within the grace window, clear the block. The daemon is the block's
    /// owner — if it was SIGKILLed (logout kills LaunchAgents; this root LaunchDaemon survives),
    /// nothing else would ever release `disablesleep`.
    private func connectionEnded() {
        let (remaining, generation) = connectionState.withLock {
            $0.connections -= 1
            $0.generation += 1
            return ($0.connections, $0.generation)
        }
        guard remaining <= 0, blocker.isBlocked else { return }
        log.notice("last daemon connection dropped while blocked — dead-man check in \(Self.deadManGrace)s")
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.deadManGrace) { [weak self] in
            guard let self else { return }
            let (connections, currentGeneration) = connectionState.withLock { ($0.connections, $0.generation) }
            guard currentGeneration == generation, connections <= 0, blocker.isBlocked else { return }
            log.warning("no daemon connection for \(Self.deadManGrace)s while blocked — clearing sleep block")
            try? blocker.set(blocked: false)
        }
    }
}
