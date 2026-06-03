import AdrafinilShared
import Foundation
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
        init(daemon: Daemon) {
            self.daemon = daemon
        }

        func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            // Defense in depth: only accept connections from binaries we signed.
            guard CallerVerifier.isAuthorized(newConnection) else { return false }
            newConnection.exportedInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
            newConnection.exportedObject = DaemonXPCService(daemon: daemon)
            // The app exports an AppXPCProtocol object so we can push status changes back to it
            // (see DaemonXPCService.subscribe). The remote interface must be set for the callback
            // proxy to be usable.
            newConnection.remoteObjectInterface = NSXPCInterface(with: AppXPCProtocol.self)
            // Drop any push registration for this connection when it goes away. Handlers fire on a
            // private queue, so hop to the main actor (the broadcaster's isolation). `key` is a
            // Sendable value identity — it lets us deregister without capturing the connection.
            let key = ObjectIdentifier(newConnection)
            let daemon = daemon
            let drop: @Sendable () -> Void = { Task { @MainActor in daemon.statusBroadcaster.remove(key: key) } }
            newConnection.invalidationHandler = drop
            newConnection.interruptionHandler = drop
            newConnection.resume()
            return true
        }
    }
}

/// Holds the menu bar app's push-callback proxies and fans `DaemonStatus` out to them. Keyed by the
/// connection's object identity so a connection's invalidation can deregister it without retaining
/// the connection. Encodes once per broadcast, not once per subscriber.
@MainActor
final class StatusBroadcaster {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "StatusBroadcaster")
    private var subscribers: [ObjectIdentifier: any AppXPCProtocol] = [:]

    func add(_ proxy: any AppXPCProtocol, key: ObjectIdentifier) {
        subscribers[key] = proxy
        log.debug("Subscriber added (\(self.subscribers.count) total)")
    }

    func remove(key: ObjectIdentifier) {
        guard subscribers.removeValue(forKey: key) != nil else { return }
        log.debug("Subscriber removed (\(self.subscribers.count) total)")
    }

    func broadcast(_ status: DaemonStatus) {
        guard !subscribers.isEmpty, let data = try? JSONEncoder().encode(status) else { return }
        // A push to a dead connection is dropped silently by NSXPC; the subscriber re-subscribes on
        // reconnect, so there is nothing to handle here.
        for proxy in subscribers.values {
            proxy.statusChanged(data)
        }
    }
}

final class DaemonXPCService: NSObject, DaemonXPCProtocol, @unchecked Sendable {
    let daemon: Daemon
    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func status(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            do {
                let s = await daemon.currentStatus()
                try r.call(JSONEncoder().encode(s), nil)
            } catch {
                r.call(nil, error)
            }
        }
    }

    func subscribe(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let r = SendableReply(reply)
        // `NSXPCConnection.current()` is only valid synchronously inside the call. Capture the
        // calling connection's callback proxy and identity here, then register on the main actor.
        // The proxy is safe to call from any thread; the box carries it across the isolation hop.
        guard let conn = NSXPCConnection.current() else { r.call(nil, nil); return }
        let key = ObjectIdentifier(conn)
        let proxyBox = UncheckedSendableBox(conn.remoteObjectProxy)
        Task { @MainActor in
            if let proxy = proxyBox.value as? any AppXPCProtocol {
                daemon.statusBroadcaster.add(proxy, key: key)
            }
            do {
                let s = await daemon.currentStatus()
                try r.call(JSONEncoder().encode(s), nil)
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

    func releaseAssertion(key: String, reply: @escaping @Sendable (Bool) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            let existed = await daemon.handleRelease(key: key)
            r.call(existed)
        }
    }

    func setPaused(_ paused: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            await daemon.handleSetPaused(paused)
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
        reply(AdrafinilConstants.marketingVersion)
    }

    func consumeAwaySummary(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let r = SendableReply(reply)
        Task { @MainActor in
            guard let summary = daemon.consumeAwaySummary() else {
                r.call(nil, nil)
                return
            }
            do {
                try r.call(JSONEncoder().encode(summary), nil)
            } catch {
                r.call(nil, error)
            }
        }
    }
}

/// Carries a non-Sendable value across an isolation hop where the programmer guarantees safety.
/// Used for an NSXPC callback proxy — proxies are thread-safe to invoke, but `Any` isn't `Sendable`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

/// Tiny wrapper that promises Sendable for an XPC reply block. Safe because XPC
/// reply blocks are designed to be invoked exactly once from any queue.
private final class SendableReply<each Arg>: @unchecked Sendable {
    private let block: (repeat each Arg) -> Void
    init(_ block: @escaping (repeat each Arg) -> Void) {
        self.block = block
    }
    func call(_ args: repeat each Arg) {
        block(repeat each args)
    }
}
