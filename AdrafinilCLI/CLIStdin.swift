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
    static func sessionID() -> String? {
        guard let data = readPayload(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["session_id"] as? String,
              !sid.isEmpty else { return nil }
        return sid
    }

    /// Reads the hook payload without ever stalling the agent. The payload can arrive split
    /// across multiple pipe writes (a `UserPromptSubmit` payload carries the full prompt text,
    /// which easily exceeds one write or even the 64 KB pipe capacity), so a single read isn't
    /// enough — but stdin attached to an open pipe with no hook payload (an SSH channel, manual
    /// invocation) must not hang either. So: poll briefly for the first byte, then keep reading
    /// until EOF, until the accumulated buffer parses as JSON (the writer may keep the pipe
    /// open), or until a hard deadline.
    private static func readPayload() -> Data? {
        let fd = FileHandle.standardInput.fileDescriptor
        guard isatty(fd) == 0 else { return nil }

        let deadline = Date().addingTimeInterval(0.3)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let waitMs: Int32 = data.isEmpty ? 100 : Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, waitMs) > 0, (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 else {
                return data.isEmpty ? nil : data
            }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return data.isEmpty ? nil : data } // 0 is EOF; -1 is error
            data.append(contentsOf: buffer.prefix(n))
            if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
            // Bound both time and memory against a pathological writer.
            if Date() >= deadline || data.count > 4 * 1_024 * 1_024 { return data }
        }
    }
}
