import Foundation
import AdrafinilShared

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept connections from binaries signed by us. The daemon is the only
        // legitimate caller in practice. (Verifier lives in AdrafinilShared so the
        // daemon's app-facing listener can reuse it.)
        guard CallerVerifier.isAuthorized(newConnection) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperXPCService()
        newConnection.invalidationHandler = { /* log */ }
        newConnection.interruptionHandler = { /* log */ }
        newConnection.resume()
        return true
    }
}
