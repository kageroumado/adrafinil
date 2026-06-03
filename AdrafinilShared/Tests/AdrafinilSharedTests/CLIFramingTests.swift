import Foundation
import Testing
@testable import AdrafinilShared

@Suite("CLIFraming")
struct CLIFramingTests {
    @Test
    func `roundtrip request`() throws {
        let req = CLIRequest(
            op: .acquire,
            key: "claude-code:abc",
            tool: "claude-code",
            reason: "tests",
            pid: 1_234,
            processName: "claude",
            ttlSeconds: 60,
        )
        let frame = try CLIFraming.encode(req)
        let decoded = try decode(CLIRequest.self, from: frame)
        #expect(decoded.op == .acquire)
        #expect(decoded.key == req.key)
        #expect(decoded.tool == req.tool)
        #expect(decoded.reason == req.reason)
        #expect(decoded.pid == req.pid)
        #expect(decoded.ttlSeconds == req.ttlSeconds)
    }

    @Test
    func `roundtrip response`() throws {
        let resp = CLIResponse(ok: true, error: nil, blocking: true, assertionCount: 3, statusJSON: Data("{}".utf8))
        let frame = try CLIFraming.encode(resp)
        let decoded = try decode(CLIResponse.self, from: frame)
        #expect(decoded.ok == true)
        #expect(decoded.assertionCount == 3)
        #expect(decoded.statusJSON == Data("{}".utf8))
    }

    @Test
    func `wire keys match spec`() throws {
        let req = CLIRequest(op: .acquire, key: "k", tool: "t", reason: nil, pid: 1, processName: nil, ttlSeconds: 30)
        let reqJSON = try String(decoding: JSONEncoder().encode(req), as: UTF8.self)
        #expect(reqJSON.contains("\"ttl\""))
        #expect(!reqJSON.contains("ttlSeconds"))

        let resp = CLIResponse(ok: true, error: nil, blocking: true, assertionCount: 1, statusJSON: nil, warning: "w")
        let respJSON = try String(decoding: JSONEncoder().encode(resp), as: UTF8.self)
        #expect(respJSON.contains("\"blockingState\""))
        #expect(respJSON.contains("\"warning\""))
        #expect(!respJSON.contains("\"blocking\":"))
    }

    @Test
    func `response warning roundtrips`() throws {
        let resp = CLIResponse(ok: true, error: nil, blocking: false, assertionCount: 0, statusJSON: nil, warning: "unknown key")
        let frame = try CLIFraming.encode(resp)
        let decoded = try decode(CLIResponse.self, from: frame)
        #expect(decoded.warning == "unknown key")
        #expect(decoded.blocking == false)
    }

    @Test
    func `frame prefix is big endian length`() throws {
        let req = CLIRequest(op: .ping, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
        let frame = try CLIFraming.encode(req)
        #expect(frame.count >= 4)
        let len = frame.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        #expect(Int(len) == frame.count - 4)
    }

    @Test
    func `read frame rejects oversize`() throws {
        // Craft a frame claiming 32MB — should throw.
        var bogus = Data()
        let claimed: UInt32 = (32 * 1_024 * 1_024).bigEndian
        withUnsafeBytes(of: claimed) { bogus.append(contentsOf: $0) }

        var offset = 0
        let read: (Int) throws -> Data = { count in
            let slice = bogus.subdata(in: offset ..< min(offset + count, bogus.count))
            offset += count
            return slice
        }
        #expect(throws: NSError.self) {
            _ = try CLIFraming.readFrame(read: read)
        }
    }

    @Test
    func `read frame rejects short length`() {
        var offset = 0
        let truncated = Data([0x00, 0x00]) // only 2 bytes, length needs 4
        let read: (Int) throws -> Data = { count in
            let slice = truncated.subdata(in: offset ..< min(offset + count, truncated.count))
            offset += count
            return slice
        }
        #expect(throws: NSError.self) {
            _ = try CLIFraming.readFrame(read: read)
        }
    }

    @Test
    func `decodes ttl from external JSON`() throws {
        // An external tool writing the documented wire shape uses "ttl", not "ttlSeconds".
        let json = Data(#"{"op":"acquire","key":"k","tool":"t","ttl":45}"#.utf8)
        let req = try JSONDecoder().decode(CLIRequest.self, from: json)
        #expect(req.ttlSeconds == 45)
        #expect(req.op == .acquire)
    }

    @Test
    func `response decodes when warning absent`() throws {
        // A response from an older daemon has no "warning" key.
        let json = Data(#"{"ok":true,"blockingState":true,"assertionCount":2}"#.utf8)
        let resp = try JSONDecoder().decode(CLIResponse.self, from: json)
        #expect(resp.ok == true)
        #expect(resp.blocking == true)
        #expect(resp.warning == nil)
    }

    @Test
    func `read frame rejects exactly at size limit`() {
        // The guard is `len < 16MB`; exactly 16MB must be rejected.
        var data = Data()
        let claimed = UInt32(16 * 1_024 * 1_024).bigEndian
        withUnsafeBytes(of: claimed) { data.append(contentsOf: $0) }
        var offset = 0
        let read: (Int) throws -> Data = { count in
            let slice = data.subdata(in: offset ..< min(offset + count, data.count)); offset += count; return slice
        }
        #expect(throws: NSError.self) { _ = try CLIFraming.readFrame(read: read) }
    }

    @Test
    func `request omits nil fields on wire`() throws {
        let req = CLIRequest(op: .release, key: "k", tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
        let json = try String(decoding: JSONEncoder().encode(req), as: UTF8.self)
        #expect(json.contains("\"key\""))
        #expect(!json.contains("\"tool\""))
        #expect(!json.contains("\"ttl\""))
    }

    /// Helper: decode a frame body that was encoded by `CLIFraming.encode`.
    private func decode<T: Decodable>(_: T.Type, from frame: Data) throws -> T {
        var offset = 0
        let read: (Int) throws -> Data = { count in
            let slice = frame.subdata(in: offset ..< min(offset + count, frame.count))
            offset += count
            return slice
        }
        let body = try CLIFraming.readFrame(read: read)
        return try JSONDecoder().decode(T.self, from: body)
    }
}
