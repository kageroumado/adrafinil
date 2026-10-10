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
/// `PreToolUse` payloads also carry the tool call itself (`tool_name`, `tool_input`), which the
/// background-task hook reads to tell a backgrounded Bash command or a Monitor from a foreground call.
///
/// This is the pure, testable core; `CLIStdin` reads the bytes off stdin and delegates here.
public enum HookPayload {
    /// The parent-session field on every hook payload.
    public static let sessionIDField = "session_id"
    /// The sub-agent-id field on `SubagentStart`/`SubagentStop` payloads.
    public static let agentIDField = "agent_id"
    /// The nested container of a tool call's raw input arguments on a `PreToolUse` payload.
    public static let toolInputField = "tool_input"
    /// The Bash tool's flag that launches a command in the background.
    public static let runInBackgroundField = "run_in_background"
    /// The name of the tool a `PreToolUse` payload is about.
    public static let toolNameField = "tool_name"
    /// Claude Code's Monitor tool: a background watch that streams a command's (or WebSocket's)
    /// output back to the agent as events until it ends or its deadline passes.
    public static let monitorToolName = "Monitor"
    /// The Monitor tool's deadline, in milliseconds.
    public static let timeoutMsField = "timeout_ms"
    /// The Monitor tool's legacy no-deadline flag (runs until stopped or the session ends).
    public static let persistentField = "persistent"

    /// How long a Monitor call may run, read from its `PreToolUse` payload.
    public enum MonitorDeadline: Equatable {
        /// The monitor is killed after this many seconds (`timeout_ms`), if it hasn't ended first.
        case seconds(TimeInterval)
        /// `persistent: true` — no deadline of its own.
        case persistent
    }

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

    /// Whether a `PreToolUse` Bash payload carries `tool_input.run_in_background == true`.
    ///
    /// `tool_input` is the raw argument object the model passed the tool (verified against Claude
    /// Code 2.1.201: the Bash tool's schema declares `run_in_background` as an optional boolean, so
    /// when the model sets it, it lands here). Returns false when the field is absent, not a bool,
    /// `tool_input` isn't a nested object, or the payload isn't a JSON object at all — so a
    /// foreground Bash call, or any non-Bash tool, reads as "not background" and places no hold.
    /// Only Claude Code emits this cleanly; Codex models background shells as a separate
    /// `exec_command`/`write_stdin` PTY yield with no equivalent pre-tool boolean (see
    /// `BackgroundBashHold`), so it never reaches here.
    public static func runInBackground(in data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolInput = obj[toolInputField] as? [String: Any],
              let flag = toolInput[runInBackgroundField] as? Bool else { return false }
        return flag
    }

    /// The deadline of a `PreToolUse` Monitor call, or nil when the payload isn't one.
    ///
    /// Verified against Claude Code 2.1.296: a hook matched to `Monitor` receives
    /// `tool_name: "Monitor"` and the model's raw `tool_input` — `timeout_ms` (default 300000, at most
    /// 3600000) and, on builds that still offer it, `persistent`. An absent or non-numeric
    /// `timeout_ms` reads as the tool's default, and an over-long one as its maximum, so the hold
    /// never outlasts what Claude Code itself would allow.
    public static func monitorDeadline(in data: Data) -> MonitorDeadline? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj[toolNameField] as? String == monitorToolName else { return nil }
        let toolInput = obj[toolInputField] as? [String: Any] ?? [:]
        if toolInput[persistentField] as? Bool == true { return .persistent }
        let defaultMs: Double = 300_000
        let maxMs: Double = 3_600_000
        let ms = (toolInput[timeoutMsField] as? NSNumber)?.doubleValue ?? defaultMs
        let clamped = ms.isFinite && ms > 0 ? min(ms, maxMs) : defaultMs
        return .seconds(clamped / 1_000)
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
