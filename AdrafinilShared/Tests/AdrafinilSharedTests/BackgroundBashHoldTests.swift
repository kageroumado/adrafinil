import Foundation
import Testing
@testable import AdrafinilShared

/// The pure acquire decision behind `acquire --if-background` (issue #7 Part 2). The CLI reads the
/// stdin payload and the owning PID around it, but the load-bearing logic — *whether* to place a hold
/// for a `PreToolUse` payload, and with what key and TTL — lives in `BackgroundBashHold.plan` and is
/// exercised here against crafted payloads with a fixed `uniqueID` for determinism.
@Suite("BackgroundBashHold")
struct BackgroundBashHoldTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func backgroundPayload(command: String = "npm run build") -> Data {
        data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"\#(command)","run_in_background":true}}"#)
    }

    // MARK: - Background → place a hold

    @Test
    func `a backgrounded command yields a bg-keyed plan`() {
        let plan = BackgroundBashHold.plan(
            payload: backgroundPayload(),
            tool: "claude-code",
            requestedTTL: nil,
            uniqueID: "abc123",
        )
        // Keyed <tool>:bg-<id> — namespaced so it never collides with a per-turn <tool>:<session_id>.
        #expect(plan?.key == "claude-code:bg-abc123")
    }

    @Test
    func `a plan without an explicit TTL uses the default ceiling`() {
        let plan = BackgroundBashHold.plan(
            payload: backgroundPayload(),
            tool: "claude-code",
            requestedTTL: nil,
            uniqueID: "x",
        )
        // The default is the 24h ceiling; the daemon clamps it down to the live max-hold.
        #expect(plan?.ttl == BackgroundBashHold.defaultTTLSeconds)
        #expect(BackgroundBashHold.defaultTTLSeconds == 24 * 60 * 60)
    }

    @Test
    func `an explicit TTL passes through the plan`() {
        // The installed hook always carries `--ttl`; the daemon, not this decision, applies the cap.
        let plan = BackgroundBashHold.plan(
            payload: backgroundPayload(),
            tool: "claude-code",
            requestedTTL: 3_600,
            uniqueID: "x",
        )
        #expect(plan?.ttl == 3_600)
    }

    @Test
    func `each invocation keys on its own id so overlapping tasks are independent`() {
        let a = BackgroundBashHold.plan(payload: backgroundPayload(), tool: "claude-code", requestedTTL: nil, uniqueID: "a")
        let b = BackgroundBashHold.plan(payload: backgroundPayload(), tool: "claude-code", requestedTTL: nil, uniqueID: "b")
        #expect(a?.key != b?.key, "two background tasks must not share — and thus can't release — one hold")
    }

    // MARK: - Not background → no hold

    @Test
    func `a foreground command yields no plan`() {
        let payload = data(#"{"tool_name":"Bash","tool_input":{"command":"ls","run_in_background":false}}"#)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: nil, uniqueID: "x") == nil)
    }

    @Test
    func `an absent flag yields no plan`() {
        let payload = data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: nil, uniqueID: "x") == nil)
    }

    @Test
    func `a malformed or empty payload yields no plan`() {
        #expect(BackgroundBashHold.plan(payload: data("not json"), tool: "claude-code", requestedTTL: nil, uniqueID: "x") == nil)
        #expect(BackgroundBashHold.plan(payload: Data(), tool: "claude-code", requestedTTL: nil, uniqueID: "x") == nil)
    }

    // MARK: - Fresh id

    @Test
    func `freshID is short and unique`() {
        let id = BackgroundBashHold.freshID()
        #expect(id.count == 8)
        #expect(BackgroundBashHold.freshID() != BackgroundBashHold.freshID())
    }
}
