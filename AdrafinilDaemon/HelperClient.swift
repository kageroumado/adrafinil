import Foundation
import AdrafinilShared
import OSLog

@MainActor
final class HelperClient {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "HelperClient")
    private var connection: NSXPCConnection?
    private(set) var isConnected: Bool = false
    private var desiredBlockedState: Bool = false

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: AdrafinilConstants.helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleInvalidation() }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        c.resume()
        connection = c
        isConnected = true
        return c
    }

    func setBlocked(_ blocked: Bool) async {
        desiredBlockedState = blocked
        let conn = ensureConnection()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Resume exactly once: the error handler and the reply can, in rare interruption
            // races, both fire — a double resume would trap the continuation.
            let once = OnceResumer<Void> { cont.resume() }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.log.error("Helper proxy error: \(error.localizedDescription)")
                once.resume(())
            }) as? HelperXPCProtocol else {
                once.resume(())
                return
            }
            proxy.setSleepBlocked(blocked) { [weak self] applied, error in
                if let error {
                    self?.log.error("Helper setSleepBlocked error: \(error.localizedDescription)")
                } else {
                    self?.log.info("Helper applied blocked=\(applied)")
                }
                once.resume(())
            }
        }
    }

    private func handleInvalidation() {
        log.warning("Helper XPC invalidated (helper crashed or was terminated)")
        connection = nil
        isConnected = false
        // A crash while sleep was blocked is the worst case (SPEC §4): respawn the helper
        // (the next setBlocked recreates the connection, which relaunches it via launchd; the
        // helper resets disablesleep to 0 on init) and reapply the desired state. Only bother
        // if we actually want sleep blocked — if we wanted it allowed, a dead helper already
        // means sleep is allowed, so there's nothing to reapply.
        if desiredBlockedState {
            Task { @MainActor in await setBlocked(true) }
        }
    }

    private func handleInterruption() {
        log.warning("Helper XPC interrupted — will reapply on next call")
        connection = nil
        isConnected = false
        if desiredBlockedState {
            Task { @MainActor in await setBlocked(true) }
        }
    }
}
