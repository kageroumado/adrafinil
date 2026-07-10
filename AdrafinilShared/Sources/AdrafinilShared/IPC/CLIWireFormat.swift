import Foundation

// Length-prefixed JSON over Unix socket. Used by the `adrafinil` CLI.
//
// Frame format: `[UInt32 big-endian length][JSON body]`.

public struct CLIRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        case acquire
        case release
        case status
        case ping
        /// Place an explicit agent hold. The daemon mints the `hold:` key, clamps the TTL, and
        /// returns the key in `CLIResponse.holdKey`. Release it later with `op == .release`.
        case hold
        /// Force-release every assertion (`adrafinil release --all`) — the remote counterpart
        /// of the menu bar's force release, e.g. over SSH against a closed lid. A user action,
        /// so the daemon attributes the pre-sleep cue accordingly.
        case releaseAll
    }

    public let op: Op
    public let key: String?
    public let tool: String?
    public let reason: String?
    public let pid: pid_t?
    public let processName: String?
    public let ttlSeconds: TimeInterval?

    /// Wire keys match the documented protocol: `ttlSeconds` serializes as `ttl`.
    enum CodingKeys: String, CodingKey {
        case op
        case key
        case tool
        case reason
        case pid
        case processName
        case ttlSeconds = "ttl"
    }

    public init(op: Op, key: String?, tool: String?, reason: String?, pid: pid_t?, processName: String?, ttlSeconds: TimeInterval?) {
        self.op = op
        self.key = key
        self.tool = tool
        self.reason = reason
        self.pid = pid
        self.processName = processName
        self.ttlSeconds = ttlSeconds
    }
}

public struct CLIResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String?
    public let blocking: Bool?
    public let assertionCount: Int?
    public let statusJSON: Data?
    /// Non-fatal advisory, e.g. releasing an unknown key ("warnings, not errors").
    public let warning: String?
    /// The minted `hold:` key for a successful `.hold` request, so the caller can release it later.
    public let holdKey: String?
    /// The TTL the daemon actually applied to a `.hold` (it clamps to the user's configured
    /// cap), so the caller reports a truthful duration instead of echoing what was requested.
    public let appliedTTLSeconds: TimeInterval?
    /// How many assertions a `.releaseAll` dropped (distinct from `assertionCount`, which is
    /// always the number still active after the operation).
    public let releasedCount: Int?

    /// Wire keys match the documented protocol: `blocking` serializes as `blockingState`.
    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case assertionCount
        case statusJSON
        case warning
        case holdKey
        case appliedTTLSeconds
        case releasedCount
        case blocking = "blockingState"
    }

    public init(ok: Bool, error: String?, blocking: Bool?, assertionCount: Int?, statusJSON: Data?, warning: String? = nil, holdKey: String? = nil, appliedTTLSeconds: TimeInterval? = nil, releasedCount: Int? = nil) {
        self.ok = ok
        self.error = error
        self.blocking = blocking
        self.assertionCount = assertionCount
        self.statusJSON = statusJSON
        self.warning = warning
        self.holdKey = holdKey
        self.appliedTTLSeconds = appliedTTLSeconds
        self.releasedCount = releasedCount
    }
}

public enum CLIFraming {
    public static func encode(_ value: some Encodable) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        return frame
    }

    public static func readFrame(read: (Int) throws -> Data) throws -> Data {
        let lenBytes = try read(4)
        guard lenBytes.count == 4 else {
            throw NSError(
                domain: "Adrafinil.CLIFraming",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Short read on length"],
            )
        }
        let len = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard len < 16 * 1_024 * 1_024 else {
            throw NSError(
                domain: "Adrafinil.CLIFraming",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Frame too large"],
            )
        }
        let body = try read(Int(len))
        guard body.count == len else {
            throw NSError(
                domain: "Adrafinil.CLIFraming",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Short read on body"],
            )
        }
        return body
    }
}
