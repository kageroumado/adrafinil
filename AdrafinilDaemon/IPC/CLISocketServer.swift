import AdrafinilShared
import Darwin
import Foundation
import OSLog

/// Unix-domain socket server for the `adrafinil` CLI. Length-prefixed JSON.
@MainActor
final class CLISocketServer {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "CLISocket")
    // `nonisolated` so the socket worker (which runs on `queue`, not the main actor) can read it
    // directly. `Daemon` is `@MainActor` and therefore Sendable; we only hop onto its actor via
    // `runOnMain` before touching its state.
    private nonisolated let daemon: Daemon
    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "glass.kagerou.Adrafinil.Daemon.CLISocket")

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func start() {
        let socketURL = AdrafinilConstants.cliSocketURL
        let path = socketURL.path
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            // The daemon still runs (monitors + app XPC); only the CLI surface is unavailable.
            log.error("Socket path too long for sockaddr_un (\(pathBytes.count) bytes) — CLI socket disabled")
            Darwin.close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dstChars in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dstChars, src.baseAddress!, src.count)
                }
            }
        }

        // bind() creates the socket node with `0777 & ~umask`; tightening the umask first means
        // the node is never visible with looser permissions than its final 0600. `start()` runs
        // once at daemon startup before any worker threads exist, so the process-global umask
        // flip can't race another file creation.
        let savedUmask = umask(0o177)
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrLen)
            }
        }
        umask(savedUmask)
        guard bindResult == 0 else {
            log.error("bind() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // Restrict to current user.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            log.error("listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The handler runs on `queue` (a background serial queue). `setEventHandler`'s parameter
        // is not `@Sendable`, so a closure literal written here — inside a `@MainActor` method —
        // would inherit MainActor isolation and trap at runtime when libdispatch invokes it
        // off-main (Swift 6.2 makes that isolation mismatch fatal). Typing it `@Sendable`
        // detaches it from the actor; it only captures `self` weakly and the value `fd`, and
        // calls the `nonisolated` `acceptOne`.
        let handler: @Sendable () -> Void = { [weak self] in
            self?.acceptOne(listenFD: fd)
        }
        src.setEventHandler(handler: handler)
        src.resume()
        listenSource = src
        log.info("CLI socket listening at \(path)")
    }

    private nonisolated func acceptOne(listenFD: Int32) {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // Each connection is handled by a blocking read on a global-queue worker. Without
        // deadlines, a client that connects and never sends (or never reads) parks that worker
        // forever, and enough of them exhausts the dispatch thread pool.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handle(clientFD: client)
        }
    }

    private nonisolated func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        do {
            let body = try CLIFraming.readFrame { count in
                try Self.readExact(fd: clientFD, count: count)
            }
            let req = try JSONDecoder().decode(CLIRequest.self, from: body)
            let resp = process(req)
            let frame = try CLIFraming.encode(resp)
            try Self.writeAll(fd: clientFD, data: frame)
        } catch {
            // Best-effort; client will see EOF.
        }
    }

    private nonisolated func process(_ req: CLIRequest) -> CLIResponse {
        let daemonRef = daemon
        switch req.op {
        case .ping:
            return CLIResponse(ok: true, error: nil, blocking: nil, assertionCount: nil, statusJSON: nil)

        case .acquire:
            guard let key = req.key, let tool = req.tool else {
                return CLIResponse(ok: false, error: "acquire requires key and tool", blocking: nil, assertionCount: nil, statusJSON: nil)
            }
            if let rejection = CLIRequestValidator.acquireRejection(key: key, tool: tool) {
                return CLIResponse(ok: false, error: rejection, blocking: nil, assertionCount: nil, statusJSON: nil)
            }
            let assertion = Assertion(
                key: key,
                tool: tool,
                reason: CLIRequestValidator.clampedReason(req.reason),
                pid: req.pid ?? -1,
                processName: req.processName ?? tool,
                ttl: CLIRequestValidator.clampedTTL(req.ttlSeconds),
            )
            let result: (outcome: Daemon.AcquireResult, snapshot: [Assertion]) = runOnMain { @MainActor in
                let outcome = await daemonRef.handleAcquire(assertion)
                return await (outcome, daemonRef.registry.snapshot())
            }
            switch result.outcome {
            case .accepted:
                return CLIResponse(ok: true, error: nil, blocking: !result.snapshot.isEmpty, assertionCount: result.snapshot.count, statusJSON: nil)
            case .paused:
                // A paused daemon ignoring an acquire is expected behavior, not a hook failure.
                return CLIResponse(ok: true, error: nil, blocking: false, assertionCount: result.snapshot.count, statusJSON: nil, warning: "Adrafinil is paused — acquire ignored")
            case .overCapacity:
                return CLIResponse(ok: false, error: "too many active assertions", blocking: !result.snapshot.isEmpty, assertionCount: result.snapshot.count, statusJSON: nil)
            case let .cutoutLatched(message):
                return CLIResponse(ok: false, error: message, blocking: false, assertionCount: result.snapshot.count, statusJSON: nil)
            }

        case .hold:
            let result = runOnMain { @MainActor in
                await daemonRef.handleHold(reason: req.reason, requestedTTL: req.ttlSeconds, pid: req.pid, tool: req.tool)
            }
            switch result {
            case let .placed(key, ttl, count):
                return CLIResponse(ok: true, error: nil, blocking: count > 0, assertionCount: count, statusJSON: nil, holdKey: key, appliedTTLSeconds: ttl)
            case .disabled:
                return CLIResponse(ok: false, error: "Agent holds are turned off in Adrafinil settings.", blocking: nil, assertionCount: nil, statusJSON: nil)
            case .paused:
                return CLIResponse(ok: false, error: "Adrafinil is paused — resume it to place a hold.", blocking: nil, assertionCount: nil, statusJSON: nil)
            case let .rejected(message):
                return CLIResponse(ok: false, error: message, blocking: nil, assertionCount: nil, statusJSON: nil)
            }

        case .release:
            guard let key = req.key else {
                return CLIResponse(ok: false, error: "release requires key", blocking: nil, assertionCount: nil, statusJSON: nil)
            }
            let result: (existed: Bool, snapshot: [Assertion]) = runOnMain { @MainActor in
                let existed = await daemonRef.handleRelease(key: key)
                return await (existed, daemonRef.registry.snapshot())
            }
            // Unknown-key release is a no-op, not an error — surface a warning.
            let warning = result.existed ? nil : "no assertion for key '\(key)' — released nothing"
            return CLIResponse(
                ok: true,
                error: nil,
                blocking: !result.snapshot.isEmpty,
                assertionCount: result.snapshot.count,
                statusJSON: nil,
                warning: warning,
            )

        case .releaseAll:
            let releasedCount: Int = runOnMain { @MainActor in
                let count = await daemonRef.registry.count
                await daemonRef.handleForceReleaseAll()
                return count
            }
            return CLIResponse(
                ok: true,
                error: nil,
                blocking: false,
                assertionCount: 0,
                statusJSON: nil,
                warning: releasedCount == 0 ? "nothing was held — released nothing" : nil,
                releasedCount: releasedCount,
            )

        case .status:
            let status: DaemonStatus = runOnMain { @MainActor in
                await daemonRef.currentStatus()
            }
            let json = try? JSONEncoder().encode(status)
            return CLIResponse(ok: true, error: nil, blocking: status.isBlocking, assertionCount: status.assertions.count, statusJSON: json)
        }
    }

    /// Sync-to-async bridge for the socket worker thread. Boxes the result so
    /// Swift 6's "sending" checker doesn't trip on mutated locals.
    private nonisolated func runOnMain<T: Sendable>(_ body: @escaping @Sendable @MainActor () async -> T) -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await body()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    // MARK: - Socket utilities

    nonisolated static func readExact(fd: Int32, count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: read), count - read)
            }
            if n <= 0 { break }
            read += n
        }
        return Data(buf.prefix(read))
    }

    nonisolated static func writeAll(fd: Int32, data: Data) throws {
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), data.count - written)
            }
            if n <= 0 { break }
            written += n
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
