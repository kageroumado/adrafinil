import AdrafinilShared
import Darwin
import Foundation

/// Tiny Unix-socket client for talking to AdrafinilDaemon. Single round trip per call.
enum DaemonSocketClient {
    enum ClientError: Swift.Error, LocalizedError {
        case daemonUnreachable
        case io(String)
        case decode(String)
        var errorDescription: String? {
            switch self {
            case .daemonUnreachable: "Adrafinil daemon is not running."
            case let .io(m): "Socket I/O failed: \(m)"
            case let .decode(m): "Bad response from daemon: \(m)"
            }
        }
    }

    static func send(_ request: CLIRequest) throws -> CLIResponse {
        let path = AdrafinilConstants.cliSocketURL.path

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.io("socket() failed: \(errnoString())") }
        defer { Darwin.close(fd) }

        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        // Sending is local and instant, but the reply waits on the daemon's main actor, which can
        // be busy with a helper round-trip or a state write — the receive deadline only exists to
        // bound the wedged-daemon case, so it must comfortably exceed normal daemon latency. A
        // timeout after the request was delivered means the operation may have APPLIED; treating
        // it as "not placed" would orphan a minted hold key.
        var sendTV = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTV, socklen_t(MemoryLayout<timeval>.size))
        var recvTV = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTV, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.io("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { chars in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(chars, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        guard connectResult == 0 else { throw ClientError.daemonUnreachable }

        let frame = try CLIFraming.encode(request)
        try writeAll(fd: fd, data: frame)

        let respBody = try CLIFraming.readFrame { count in
            try readExact(fd: fd, count: count)
        }
        do {
            return try JSONDecoder().decode(CLIResponse.self, from: respBody)
        } catch {
            throw ClientError.decode(error.localizedDescription)
        }
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), data.count - written)
            }
            if n <= 0 {
                if errno == EINTR { continue }
                throw ClientError.io("write failed: \(errnoString())")
            }
            written += n
        }
    }

    static func readExact(fd: Int32, count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: read), count - read)
            }
            if n <= 0 {
                if n < 0, errno == EINTR { continue }
                throw ClientError.io(n == 0 ? "connection closed by daemon" : "read failed: \(errnoString())")
            }
            read += n
        }
        return Data(buf)
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
