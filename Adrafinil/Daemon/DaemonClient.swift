import AdrafinilShared
import Foundation
import os

/// Menu bar app's client for talking to AdrafinilDaemon over XPC.
///
/// One bidirectional connection serves both directions: the app's one-shot calls (status, pause,
/// release) and the daemon's pushed status updates (`statusUpdates()`). A single shared instance is
/// used app-wide so every surface rides the same connection rather than spinning up its own.
@MainActor
final class DaemonClient {
    /// App-wide client. One connection for the live status subscription and all one-shot calls.
    static let shared = DaemonClient()

    private var connection: NSXPCConnection?
    /// Set by the connection's invalidation/interruption handlers — which NSXPC fires on its
    /// own background queue, so they capture only this Sendable flag (never `self`, whose
    /// `@MainActor` isolation would trap when touched off the main actor).
    private let connectionDied = OSAllocatedUnfairLock(initialState: false)

    // MARK: Push subscription state

    /// The callback object the daemon pushes status to. Created once when `statusUpdates()` is first
    /// called; reused across reconnects (it captures the stream continuation).
    private var callback: AppStatusCallback?
    /// Feeds `statusUpdates()`'s stream. Lives as long as the subscription.
    private var statusContinuation: AsyncStream<DaemonStatus>.Continuation?
    /// Whether a caller wants pushes — drives whether we re-subscribe after a connection drops.
    private var wantsSubscription = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private static let maxBackoff: Double = 30

    enum ClientError: Error, LocalizedError {
        case noConnection
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .noConnection: "Couldn't reach Adrafinil's background helper."
            case .invalidResponse: "Adrafinil's background helper sent an unexpected response."
            }
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        // Drop a connection that died since last use, then lazily make a fresh one.
        if connectionDied.withLock({ flag -> Bool in defer { flag = false }; return flag }) {
            connection?.invalidate()
            connection = nil
        }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: AdrafinilConstants.daemonMachServiceName)
        c.remoteObjectInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
        // Export the push callback so the daemon can call back on this connection. Set before
        // `resume()`, so a connection made while a subscription is active is push-capable from the
        // start — `statusUpdates()` tears down any pre-subscription connection to force this path.
        if let callback {
            c.exportedInterface = NSXPCInterface(with: AppXPCProtocol.self)
            c.exportedObject = callback
        }
        let died = connectionDied
        let markDied: @Sendable () -> Void = { [weak self] in
            died.withLock { $0 = true }
            Task { @MainActor in self?.handleConnectionDeath() }
        }
        c.invalidationHandler = markDied
        c.interruptionHandler = markDied
        c.resume()
        connection = c
        return c
    }

    /// Performs one XPC call, resuming the continuation exactly once — whether the reply
    /// arrives or the connection fails. The per-call error handler is essential: when the
    /// daemon isn't running (e.g. before first-run setup), the message fails and only the
    /// error handler fires; without resuming there, the call would hang forever.
    private func call<T: Sendable>(
        _ invoke: @escaping @Sendable (DaemonXPCProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void,
    ) async throws -> T {
        let conn = ensureConnection()
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceResumer<Result<T, Error>> { cont.resume(with: $0) }
            // The error handler must be @Sendable (non-isolated): NSXPC calls it on its own
            // background queue, and a @MainActor-isolated closure would trap there.
            let onError: @Sendable (any Error) -> Void = { once.resume(.failure($0)) }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler(onError) as? DaemonXPCProtocol else {
                once.resume(.failure(ClientError.noConnection))
                return
            }
            invoke(proxy) { once.resume($0) }
        }
    }

    func fetchStatus() async throws -> DaemonStatus {
        try await call { proxy, done in
            proxy.status { data, error in
                if let error { done(.failure(error)); return }
                guard let data, let s = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                    done(.failure(ClientError.invalidResponse)); return
                }
                done(.success(s))
            }
        }
    }

    func forceReleaseAll() async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.forceReleaseAll { done(.success($0)) }
        }
    }

    func setPaused(_ paused: Bool) async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.setPaused(paused) { done(.success($0)) }
        }
    }

    func releaseAssertion(key: String) async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.releaseAssertion(key: key) { done(.success($0)) }
        }
    }

    func reloadSettings() async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.reloadSettings { done(.success($0)) }
        }
    }

    /// Consumes the pending "while you were away" summary from the daemon.
    ///
    /// Consume-once: the daemon clears the summary after this call. Returns `nil` when there
    /// is no pending summary or the daemon is unreachable.
    func consumeAwaySummary() async -> AwaySummary? {
        let data = try? await call { (proxy, done: @escaping @Sendable (Result<Data?, Error>) -> Void) in
            proxy.consumeAwaySummary { data, error in
                if let error { done(.failure(error)); return }
                done(.success(data))
            }
        }
        guard let bytes = data.flatMap(\.self),
              let summary = try? JSONDecoder().decode(AwaySummary.self, from: bytes) else {
            return nil
        }
        return summary
    }

    // MARK: - Push subscription

    /// A stream of `DaemonStatus` pushed by the daemon on every state change — the live alternative
    /// to polling. The daemon also returns the current snapshot on (re)subscribe, so the stream
    /// emits an initial value and recovers from daemon restarts without gaps. Intended to be called
    /// once; the returned stream stays live until the task consuming it is cancelled.
    func statusUpdates() -> AsyncStream<DaemonStatus> {
        // Buffer only the newest: a slow consumer should see current state, not a backlog.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.statusContinuation = continuation
            self.wantsSubscription = true
            // The callback runs on NSXPC's private queue; it captures the (Sendable) continuation
            // directly rather than reaching back through `self`, so no isolation hop is needed.
            self.callback = AppStatusCallback { data in
                guard let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else { return }
                continuation.yield(status)
            }
            // Force a fresh, push-capable connection (any existing one was made without the exported
            // callback), then subscribe.
            self.connection?.invalidate()
            self.connection = nil
            self.subscribeNow()
            continuation.onTermination = { [weak self] _ in
                // Fires on an arbitrary queue when the consumer cancels — hop to the main actor.
                Task { @MainActor in self?.endSubscription() }
            }
        }
    }

    /// (Re)registers for push updates over the current connection. The daemon's reply carries the
    /// current snapshot, which seeds the stream and closes any gap after a reconnect.
    private func subscribeNow() {
        guard wantsSubscription else { return }
        let conn = ensureConnection()
        let onError: @Sendable (any Error) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleConnectionDeath() }
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler(onError) as? DaemonXPCProtocol else {
            handleConnectionDeath()
            return
        }
        proxy.subscribe { [weak self] data, _ in
            // Reply lands on NSXPC's private queue — hop to the main actor to touch state.
            Task { @MainActor in
                guard let self else { return }
                self.reconnectAttempts = 0 // subscription is live — reset backoff
                if let data, let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) {
                    self.statusContinuation?.yield(status)
                }
            }
        }
    }

    /// Called when the connection drops while we still want pushes: reconnect after a widening
    /// backoff (the daemon may be relaunching via launchd). `subscribeNow` resets the backoff once
    /// the subscription is re-established.
    private func handleConnectionDeath() {
        guard wantsSubscription else { return }
        reconnectTask?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempts)), Self.maxBackoff)
        reconnectAttempts += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, wantsSubscription else { return }
            subscribeNow()
        }
    }

    private func endSubscription() {
        wantsSubscription = false
        reconnectTask?.cancel()
        reconnectTask = nil
        statusContinuation?.finish()
        statusContinuation = nil
        callback = nil
    }
}

/// The app's `AppXPCProtocol` callback object: receives status pushes from the daemon and forwards
/// them to a Sendable handler. NSXPC invokes `statusChanged` on its own private queue.
///
/// `statusChanged` **must** be `nonisolated`: under the app's MainActor-by-default isolation it
/// would otherwise be implicitly `@MainActor`, and NSXPC calling an `@objc` MainActor method from
/// its private (non-main) queue trips the Swift runtime's executor-isolation assertion
/// (`swift_task_checkIsolated` → `EXC_BREAKPOINT`). It only forwards to a `@Sendable` closure, so
/// running off-main is safe; the closure hops to the main actor as needed.
private final class AppStatusCallback: NSObject, AppXPCProtocol, @unchecked Sendable {
    private let onStatus: @Sendable (Data) -> Void
    init(onStatus: @escaping @Sendable (Data) -> Void) {
        self.onStatus = onStatus
    }
    nonisolated func statusChanged(_ encodedStatus: Data) {
        onStatus(encodedStatus)
    }
}
