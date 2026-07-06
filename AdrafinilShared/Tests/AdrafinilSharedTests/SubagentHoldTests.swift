import Foundation
import Testing
@testable import AdrafinilShared

/// The core of the sub-agent keep-awake fix (issue #7): a sub-agent hold is keyed on the sub-agent's
/// own `agent_id`, giving it a key *distinct* from the parent turn's `<tool>:<session_id>` hold. These
/// tests prove the two properties that makes correct: a foreground sub-agent's start+stop is
/// net-neutral on the parent hold, and a backgrounded sub-agent's hold survives the parent `Stop` and
/// releases only on its own `SubagentStop`.
///
/// `AssertionRegistry` is driven directly (it's the daemon's source of truth for `isBlocking`), so the
/// tests exercise the real reference-counting rather than a reimplementation.
@Suite("SubagentHold")
struct SubagentHoldTests {
    /// The registry key the CLI derives for a normal per-turn hold (`UserPromptSubmit`/`Stop`).
    private func parentKey(tool: String, session: String) -> String {
        ManualHold.sessionKey(tool: tool, sessionID: session)
    }

    /// The registry key the CLI derives for a `--subagent` hold — the sub-agent's `agent_id` in place
    /// of the parent session id.
    private func subagentKey(tool: String, agentID: String) -> String {
        ManualHold.sessionKey(tool: tool, sessionID: agentID)
    }

    private func assertion(_ key: String, tool: String) -> Assertion {
        Assertion(key: key, tool: tool, pid: 0, processName: tool, origin: .hook)
    }

    // MARK: - Key derivation

    @Test
    func `a subagent hold is a distinct key from the parent session hold`() {
        // SubagentStart/Stop emit the PARENT's session_id and the sub-agent's own agent_id. Keying on
        // agent_id (not session_id) is what makes the two holds independent.
        let parent = parentKey(tool: "claude-code", session: "sess-1")
        let sub = subagentKey(tool: "claude-code", agentID: "agent-A")
        #expect(parent == "claude-code:sess-1")
        #expect(sub == "claude-code:agent-A")
        #expect(parent != sub, "sub-agent hold must not collide with the parent turn's hold")
    }

    @Test
    func `two subagents of the same parent get distinct keys`() {
        let a = subagentKey(tool: "codex", agentID: "agent-A")
        let b = subagentKey(tool: "codex", agentID: "agent-B")
        #expect(a != b, "each sub-agent tracks its own hold, released by its own SubagentStop")
    }

    // MARK: - Foreground sub-agent (regression proof)

    /// A *foreground* sub-agent runs and finishes within the parent turn: SubagentStart → acquire,
    /// SubagentStop → release, both before the parent's `Stop`. Because the sub-agent hold is a
    /// distinct key, its start+stop is net-neutral on the parent hold — the bug being that keying it on
    /// the parent's session_id would make its SubagentStop release the parent's turn hold mid-work.
    @Test
    func `a foreground subagent start and stop leaves the parent hold intact`() async {
        let registry = AssertionRegistry()
        let parent = parentKey(tool: "claude-code", session: "sess-1")
        let sub = subagentKey(tool: "claude-code", agentID: "agent-A")

        // Parent turn begins (UserPromptSubmit) and spawns a foreground sub-agent (SubagentStart).
        await registry.acquire(assertion(parent, tool: "claude-code"))
        await registry.acquire(assertion(sub, tool: "claude-code"))
        #expect(await registry.isBlocking)
        #expect(await registry.count == 2)

        // Sub-agent finishes (SubagentStop) — releases only its own key. Parent turn still running.
        await registry.release(key: sub)
        #expect(await registry.isBlocking, "parent's turn hold must survive the sub-agent's Stop")
        #expect(await registry.count == 1)

        // Parent turn ends (Stop) — now nothing is blocking.
        await registry.release(key: parent)
        #expect(await !(registry.isBlocking), "Mac can sleep once the parent turn ends")
    }

    // MARK: - Backgrounded sub-agent (the fix)

    /// A *backgrounded* sub-agent keeps running after the parent turn's `Stop`. The parent `Stop`
    /// releases the parent key, but the sub-agent hold — a distinct key — remains, so the Mac stays
    /// awake until the sub-agent's own `SubagentStop`. This is exactly the mid-work sleep the fix
    /// prevents.
    @Test
    func `a backgrounded subagent keeps the Mac awake past the parent Stop`() async {
        let registry = AssertionRegistry()
        let parent = parentKey(tool: "codex", session: "sess-1")
        let sub = subagentKey(tool: "codex", agentID: "agent-A")

        // Parent turn begins and spawns a backgrounded sub-agent.
        await registry.acquire(assertion(parent, tool: "codex"))
        await registry.acquire(assertion(sub, tool: "codex"))
        #expect(await registry.isBlocking)

        // Parent turn ends (Stop fires) while the sub-agent is still working.
        await registry.release(key: parent)
        #expect(await registry.isBlocking, "backgrounded sub-agent must keep the Mac awake past Stop")
        #expect(await registry.count == 1)

        // The sub-agent finishes (its own SubagentStop) — only now can the Mac sleep.
        await registry.release(key: sub)
        #expect(await !(registry.isBlocking), "Mac sleeps once the backgrounded sub-agent finishes")
    }
}
