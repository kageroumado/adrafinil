import Foundation
import Testing
@testable import AdrafinilShared

@Suite("ClaudeSessionStatus")
struct ClaudeSessionStatusTests {
    private func json(_ s: String) -> Data {
        Data(s.utf8)
    }

    @Test
    func `parses a real status file shape`() {
        let status = ClaudeSessionStatus.parse(json("""
        {"pid": 37388, "sessionId": "5328115a-1c2f", "cwd": "/tmp", "version": "2.1.238",
         "kind": "interactive", "status": "waiting", "waitingFor": "approve Bash",
         "statusUpdatedAt": 1787347947387, "updatedAt": 1787347947387}
        """))
        #expect(status?.pid == 37_388)
        #expect(status?.sessionID == "5328115a-1c2f")
        #expect(status?.activity == .waiting)
        #expect(status?.waitingFor == "approve Bash")
        #expect(status?.statusUpdatedAt != nil)
    }

    @Test
    func `waitingFor is optional and empty reads as absent`() {
        let bare = ClaudeSessionStatus.parse(json(#"{"pid": 1, "sessionId": "s", "status": "busy"}"#))
        #expect(bare?.activity == .busy)
        #expect(bare?.waitingFor == nil)
        let empty = ClaudeSessionStatus.parse(json(#"{"pid": 1, "sessionId": "s", "status": "waiting", "waitingFor": ""}"#))
        #expect(empty?.waitingFor == nil)
    }

    /// The file is Claude Code internals — anything off-shape must read as "no status", never crash
    /// or guess. An unknown status string in particular means the vocabulary changed upstream.
    @Test
    func `rejects malformed and unknown content`() {
        #expect(ClaudeSessionStatus.parse(json("not json")) == nil)
        #expect(ClaudeSessionStatus.parse(json("[1,2]")) == nil)
        #expect(ClaudeSessionStatus.parse(json(#"{"pid": 0, "sessionId": "s", "status": "busy"}"#)) == nil)
        #expect(ClaudeSessionStatus.parse(json(#"{"pid": 5, "sessionId": "", "status": "busy"}"#)) == nil)
        #expect(ClaudeSessionStatus.parse(json(#"{"pid": 5, "sessionId": "s"}"#)) == nil)
        #expect(ClaudeSessionStatus.parse(json(#"{"pid": 5, "sessionId": "s", "status": "blocked"}"#)) == nil)
        #expect(ClaudeSessionStatus.parse(json(#"{"pid": "5", "sessionId": "s", "status": "busy"}"#)) == nil)
    }

    /// Only `<pid>.json` is a status file. The `<pid>.<hash>.key` files beside them are
    /// messaging-socket auth material and must never match.
    @Test
    func `filename filter matches pid json only`() {
        #expect(ClaudeSessionStatus.isStatusFilename("37388.json"))
        #expect(!ClaudeSessionStatus.isStatusFilename("37388.3247fb14.key"))
        #expect(!ClaudeSessionStatus.isStatusFilename("37388.3247fb14.json"))
        #expect(!ClaudeSessionStatus.isStatusFilename("notes.json"))
        #expect(!ClaudeSessionStatus.isStatusFilename(".json"))
        #expect(!ClaudeSessionStatus.isStatusFilename("37388"))
    }

    /// A crashed session leaves its file behind, and `--resume` re-registers the same session id
    /// under a new pid — dead pids lose, and among live ones the freshest status wins.
    @Test
    func `best prefers live pids then freshest status`() {
        let stale = ClaudeSessionStatus(pid: 100, sessionID: "s", activity: .waiting, statusUpdatedAt: Date(timeIntervalSince1970: 1_000))
        let older = ClaudeSessionStatus(pid: 200, sessionID: "s", activity: .idle, statusUpdatedAt: Date(timeIntervalSince1970: 2_000))
        let fresh = ClaudeSessionStatus(pid: 300, sessionID: "s", activity: .busy, statusUpdatedAt: Date(timeIntervalSince1970: 3_000))
        let other = ClaudeSessionStatus(pid: 400, sessionID: "t", activity: .waiting, statusUpdatedAt: Date(timeIntervalSince1970: 9_000))

        let best = ClaudeSessionStatus.best(forSession: "s", in: [stale, older, fresh, other], pidAlive: { $0 != 100 })
        #expect(best?.pid == 300)
        #expect(ClaudeSessionStatus.best(forSession: "s", in: [stale], pidAlive: { _ in false }) == nil)
        #expect(ClaudeSessionStatus.best(forSession: "missing", in: [stale, fresh], pidAlive: { _ in true }) == nil)
    }
}
