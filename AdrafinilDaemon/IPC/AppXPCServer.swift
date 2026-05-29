import Foundation
import AdrafinilShared
import OSLog

/// XPC server the menu bar app connects to.
@MainActor
final class AppXPCServer {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "AppXPCServer")
    private let listener: NSXPCListener
    private let delegate: ListenerDelegate

    init(daemon: Daemon) {
        self.listener = NSXPCListener(machServiceName: AdrafinilConstants.daemonMachServiceName)
        self.delegate = ListenerDelegate(daemon: daemon)
    }

    func start() {
        listener.delegate = delegate
        listener.resume()
        log.info("App XPC listener started on \(AdrafinilConstants.daemonMachServiceName)")
    }

    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        let daemon: Daemon
        init(daemon: Daemon) { self.daemon = daemon }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            // Defense in depth: only accept connections from binaries we signed.
            guard CallerVerifier.isAuthorized(newConnection) else { return false }
            newConnection.exportedInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
            newConnection.exportedObject = DaemonXPCService(daemon: daemon)
            newConnection.resume()
            return true
        }
    }
}

final class DaemonXPCService: NSObject, DaemonXPCProtocol, @unchecked Sendable {
    let daemon: Daemon
    init(daemon: Daemon) { self.daemon = daemon }

    func status(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            do {
                let s = await daemon.currentStatus()
                r.call(try JSONEncoder().encode(s), nil)
            } catch {
                r.call(nil, error)
            }
        }
    }

    func forceReleaseAll(reply: @escaping @Sendable (Bool) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            await daemon.handleForceReleaseAll()
            r.call(true)
        }
    }

    func reloadSettings(reply: @escaping @Sendable (Bool) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            daemon.reloadSettings()
            r.call(true)
        }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply("0.1.0")
    }

    func consumeAwaySummary(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            guard let summary = daemon.consumeAwaySummary() else {
                r.call(nil, nil)
                return
            }
            do {
                r.call(try JSONEncoder().encode(summary), nil)
            } catch {
                r.call(nil, error)
            }
        }
    }
}

/// Tiny wrapper that promises Sendable for an XPC reply block. Safe because XPC
/// reply blocks are designed to be invoked exactly once from any queue.
private final class SendableReply<each Arg>: @unchecked Sendable {
    private let block: (repeat each Arg) -> Void
    init(_ block: @escaping (repeat each Arg) -> Void) { self.block = block }
    func call(_ args: repeat each Arg) { block(repeat each args) }
}
