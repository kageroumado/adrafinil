import Foundation
import Testing
@testable import AdrafinilShared

/// The pure field extraction behind `CLIStdin.sessionID()`/`agentID()`. The byte-reading off stdin
/// isn't unit-testable, but the field parsing — which field name each reads, and the empty-string
/// rejection — is where the bugs live, so it's exercised here against crafted payloads.
@Suite("HookPayload")
struct HookPayloadTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - session_id

    @Test
    func `sessionID reads the session_id field`() {
        #expect(HookPayload.sessionID(in: data(#"{"session_id":"sess-123"}"#)) == "sess-123")
    }

    @Test
    func `sessionID ignores an agent_id-only payload`() {
        // A payload carrying only agent_id (never happens in practice, but proves the fields are
        // read independently) yields no session id.
        #expect(HookPayload.sessionID(in: data(#"{"agent_id":"agt-1"}"#)) == nil)
    }

    // MARK: - agent_id

    @Test
    func `agentID reads the agent_id field`() {
        // The SubagentStart/SubagentStop shape: the parent's session_id is present, but agentID must
        // read the sub-agent's own agent_id — the whole point of the fix.
        let payload = #"{"hook_event_name":"SubagentStart","session_id":"parent-sess","agent_id":"sub-agent-9","agent_type":"general"}"#
        #expect(HookPayload.agentID(in: data(payload)) == "sub-agent-9")
    }

    @Test
    func `agentID is distinct from the parent session_id in the same payload`() {
        // Both fields present (as SubagentStart/Stop always send): agentID and sessionID pull apart
        // exactly — this separation is what keeps the sub-agent hold from clobbering the parent's.
        let payload = #"{"session_id":"parent","agent_id":"child"}"#
        #expect(HookPayload.agentID(in: data(payload)) == "child")
        #expect(HookPayload.sessionID(in: data(payload)) == "parent")
    }

    @Test
    func `agentID is nil when agent_id is absent`() {
        // A non-sub-agent payload (UserPromptSubmit) has session_id but no agent_id.
        #expect(HookPayload.agentID(in: data(#"{"session_id":"only-session"}"#)) == nil)
    }

    // MARK: - Empty / malformed

    @Test
    func `an empty field value reads as absent`() {
        // A hook whose expansion came up empty must yield "no id", not the id "".
        #expect(HookPayload.agentID(in: data(#"{"agent_id":""}"#)) == nil)
        #expect(HookPayload.sessionID(in: data(#"{"session_id":""}"#)) == nil)
    }

    @Test
    func `non-object and non-string values are nil`() {
        #expect(HookPayload.agentID(in: data("not json")) == nil)
        #expect(HookPayload.agentID(in: data("[1,2,3]")) == nil)
        #expect(HookPayload.agentID(in: data(#"{"agent_id":42}"#)) == nil)
        #expect(HookPayload.agentID(in: Data()) == nil)
    }

    // MARK: - run_in_background (PreToolUse Bash)

    @Test
    func `runInBackground is true for a backgrounded Bash call`() {
        // The real PreToolUse shape: tool_name + the raw tool_input carrying run_in_background=true.
        let payload = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run build","run_in_background":true}}"#
        #expect(HookPayload.runInBackground(in: data(payload)) == true)
    }

    @Test
    func `runInBackground is false for a foreground Bash call`() {
        // The common case — a foreground command sets the flag false (or omits it).
        let explicit = #"{"tool_name":"Bash","tool_input":{"command":"ls","run_in_background":false}}"#
        #expect(HookPayload.runInBackground(in: data(explicit)) == false)
    }

    @Test
    func `runInBackground is false when the flag is absent`() {
        // Claude Code omits run_in_background when the model doesn't set it — must read as "not
        // background", not throw or default true.
        let payload = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        #expect(HookPayload.runInBackground(in: data(payload)) == false)
    }

    @Test
    func `runInBackground is false when tool_input is missing or not an object`() {
        // A non-Bash tool, or a malformed payload with no nested tool_input, places no hold.
        #expect(HookPayload.runInBackground(in: data(#"{"tool_name":"Read"}"#)) == false)
        #expect(HookPayload.runInBackground(in: data(#"{"tool_input":"oops"}"#)) == false)
        #expect(HookPayload.runInBackground(in: data(#"{"tool_input":{"run_in_background":"true"}}"#)) == false)
        #expect(HookPayload.runInBackground(in: data("not json")) == false)
        #expect(HookPayload.runInBackground(in: Data()) == false)
    }
}
