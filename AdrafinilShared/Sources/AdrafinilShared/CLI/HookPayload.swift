import Foundation

/// Pure extraction of the identity fields Adrafinil keys holds on out of a hook's stdin JSON payload.
///
/// Every Claude-Code-style hook system (Claude Code, Codex, Gemini CLI, Cursor) invokes the hook
/// command with a JSON object on stdin. Two fields matter to us:
///
///   - `session_id` — the parent session/turn id, present on every hook. `UserPromptSubmit`/`Stop`
///     key their per-turn hold on it.
///   - `agent_id` — a **sub-agent's own** id, present only on `SubagentStart`/`SubagentStop`. The
///     parent's `session_id` is *also* on those payloads, so a sub-agent hook that keyed on
///     `session_id` would collide with — and, being idempotent-by-key, wrongly release — the
///     parent's turn hold. Keying the sub-agent hold on `agent_id` gives it a distinct key that
///     survives the parent `Stop` and releases only on its own `SubagentStop`.
///
/// Verified against both agents' source: Claude Code (`src/utils/hooks.ts`, `SubagentStart`/
/// `SubagentStop` set `agent_id` while `createBaseHookInput` fills `session_id` with the *main*
/// session) and Codex/codex-rs (`hooks/src/schema.rs` `Subagent*CommandInput` carry `agent_id`
/// alongside `session_id`, from `thread_id()` vs the shared root `session_id()`). Both name the
/// field identically, so a single `agent_id` read covers Claude Code and Codex.
///
/// This is the pure, testable core; `CLIStdin` reads the bytes off stdin and delegates here.
public enum HookPayload {
    /// The parent-session field on every hook payload.
    public static let sessionIDField = "session_id"
    /// The sub-agent-id field on `SubagentStart`/`SubagentStop` payloads.
    public static let agentIDField = "agent_id"

    /// The parent `session_id` from a hook payload, or nil when the bytes aren't a JSON object with
    /// a non-empty string at that key.
    public static func sessionID(in data: Data) -> String? {
        string(forField: sessionIDField, in: data)
    }

    /// The sub-agent's own `agent_id` from a `SubagentStart`/`SubagentStop` payload, or nil when the
    /// bytes aren't a JSON object with a non-empty string at that key (e.g. a non-sub-agent hook).
    public static func agentID(in data: Data) -> String? {
        string(forField: agentIDField, in: data)
    }

    /// A non-empty string value at `field` in a top-level JSON object, or nil. An empty string reads
    /// as absent — a hook whose expansion came up empty must yield "no id", not the id `""`.
    public static func string(forField field: String, in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[field] as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
