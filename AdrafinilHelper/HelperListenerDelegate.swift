import Foundation
import OSLog
import AdrafinilShared

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Listener")

    /// One process-wide blocker, shared by every connection's service. Keeping the sleep-blocking
    /// state here (not per `HelperXPCService`) means a daemon reconnect reuses the live assertion
    /// instead of orphaning it — see `SleepBlocker`.
    private let blocker = SleepBlocker()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept connections from binaries signed by us. The daemon is the only
        // legitimate caller in practice. (Verifier lives in AdrafinilShared so the
        // daemon's app-facing listener can reuse it.)
        guard CallerVerifier.isAuthorized(newConnection) else {
            log.error("rejected XPC connection (pid \(newConnection.processIdentifier, privacy: .public)) — caller failed code-signing check")
            return false
        }
        log.notice("accepted XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperXPCService(blocker: blocker)
        newConnection.invalidationHandler = { [log] in log.notice("XPC connection invalidated") }
        newConnection.interruptionHandler = { [log] in log.notice("XPC connection interrupted") }
        newConnection.resume()
        return true
    }
}
