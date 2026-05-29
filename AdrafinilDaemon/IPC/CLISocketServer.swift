import Foundation
import AdrafinilShared
import OSLog
import Darwin

/// Unix-domain socket server for the `adrafinil` CLI. Length-prefixed JSON.
@MainActor
final class CLISocketServer {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "CLISocket")
    private let daemon: Daemon
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
        precondition(pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path),
                     "Socket path too long for sockaddr_un")
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dstChars in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dstChars, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrLen)
            }
        }
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
        src.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        src.resume()
        listenSource = src
        log.info("CLI socket listening at \(path)")
    }

    private nonisolated func acceptOne() {
        let listenFD = MainActor.assumeIsolated { self.listenFD }
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
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
            let resp = self.process(req)
            let frame = try CLIFraming.encode(resp)
            try Self.writeAll(fd: clientFD, data: frame)
        } catch {
            // Best-effort; client will see EOF.
        }
    }

    private nonisolated func process(_ req: CLIRequest) -> CLIResponse {
        let daemonRef = MainActor.assumeIsolated { self.daemon }
        switch req.op {
        case .ping:
            return CLIResponse(ok: true, error: nil, blocking: nil, assertionCount: nil, statusJSON: nil)

        case .acquire:
            guard let key = req.key, let tool = req.tool else {
                return CLIResponse(ok: false, error: "acquire requires key and tool", blocking: nil, assertionCount: nil, statusJSON: nil)
            }
            let assertion = Assertion(
                key: key,
                tool: tool,
                reason: req.reason,
                pid: req.pid ?? -1,
                processName: req.processName ?? tool,
                ttl: req.ttlSeconds
            )
            let snapshot = runOnMain { @MainActor in
                await daemonRef.handleAcquire(assertion)
                return await daemonRef.registry.snapshot()
            }
            return CLIResponse(ok: true, error: nil, blocking: !snapshot.isEmpty, assertionCount: snapshot.count, statusJSON: nil)

        case .release:
            guard let key = req.key else {
                return CLIResponse(ok: false, error: "release requires key", blocking: nil, assertionCount: nil, statusJSON: nil)
            }
            let result: (existed: Bool, snapshot: [Assertion]) = runOnMain { @MainActor in
                let existed = await daemonRef.handleRelease(key: key)
                return (existed, await daemonRef.registry.snapshot())
            }
            // Unknown-key release is a no-op, not an error (SPEC §5.6) — surface a warning.
            let warning = result.existed ? nil : "no assertion for key '\(key)' — released nothing"
            return CLIResponse(ok: true, error: nil, blocking: !result.snapshot.isEmpty,
                               assertionCount: result.snapshot.count, statusJSON: nil, warning: warning)

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
