import Foundation

/// Reads the agent session id from the hook's stdin payload.
///
/// Every Claude-Code-style hook system (Claude Code, Codex, Gemini CLI, Cursor) invokes the hook
/// command with a JSON object on **stdin** that includes a `session_id` field. Preferring this over
/// shell env-var substitution in the hook command (`$CLAUDE_CODE_SESSION_ID`, `$CODEX_THREAD_ID`, …)
/// makes the integration immune to per-agent env-var naming differences — the exact class of bug
/// that left Claude (`$CLAUDE_SESSION_ID` → empty) and Codex (`CODEX_THREAD_ID` is not a documented
/// hook env var) acquiring with an empty key. The env-var argument remains as a fallback.
enum CLIStdin {
    /// Returns the `session_id` from a JSON object on stdin, or nil when stdin is a terminal
    /// (manual invocation), has no data ready, or isn't the expected JSON.
    ///
    /// Never blocks: a hook writes its JSON payload immediately and we read it, but stdin attached
    /// to an open pipe with no data (e.g. an SSH channel, or `adrafinil` run by hand) must not stall
    /// the CLI. So we `poll()` briefly for readiness and do a single bounded `read()` rather than
    /// waiting for EOF (which would hang if the writer keeps the pipe open). On the hot path the
    /// payload is ready instantly; the timeout only elapses when there is no hook payload.
    static func sessionID() -> String? {
        let fd = FileHandle.standardInput.fileDescriptor
        guard isatty(fd) == 0 else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 100) > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }   // n == 0 is EOF (e.g. `< /dev/null`); -1 is error

        guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(n))) as? [String: Any],
              let sid = obj["session_id"] as? String,
              !sid.isEmpty else { return nil }
        return sid
    }
}
