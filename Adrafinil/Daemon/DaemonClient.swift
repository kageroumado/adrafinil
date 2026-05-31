import Foundation
import AdrafinilShared
import os

/// Menu bar app's client for talking to AdrafinilDaemon over XPC.
@MainActor
final class DaemonClient {
    private var connection: NSXPCConnection?
    /// Set by the connection's invalidation/interruption handlers — which NSXPC fires on its
    /// own background queue, so they capture only this Sendable flag (never `self`, whose
    /// `@MainActor` isolation would trap when touched off the main actor).
    private let connectionDied = OSAllocatedUnfairLock(initialState: false)

    enum ClientError: Error, LocalizedError {
        case noConnection
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .noConnection: "Daemon not reachable"
            case .invalidResponse: "Daemon returned invalid response"
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
        let died = connectionDied
        let markDied: @Sendable () -> Void = { died.withLock { $0 = true } }
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
        _ invoke: @escaping @Sendable (DaemonXPCProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
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
        guard let bytes = data.flatMap({ $0 }),
              let summary = try? JSONDecoder().decode(AwaySummary.self, from: bytes) else {
            return nil
        }
        return summary
    }
}
