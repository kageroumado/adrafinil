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

    // MARK: - Monitor → a hold sized to its deadline

    private func monitorPayload(_ toolInput: String) -> Data {
        data(#"{"hook_event_name":"PreToolUse","tool_name":"Monitor","tool_input":\#(toolInput)}"#)
    }

    @Test
    func `a monitor holds for its timeout plus the re-arm grace`() {
        // Shape captured from Claude Code 2.1.296's PreToolUse payload for a Monitor call.
        let payload = monitorPayload(#"{"description":"probe","timeout_ms":60000,"command":"echo hi"}"#)
        let plan = BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: 86_400, uniqueID: "m1")
        #expect(plan?.key == "claude-code:bg-m1")
        #expect(plan?.ttl == 60 + BackgroundBashHold.monitorGraceSeconds)
    }

    @Test
    func `a monitor without a timeout holds for the tool's default`() {
        let plan = BackgroundBashHold.plan(payload: monitorPayload(#"{"command":"tail -f log"}"#), tool: "claude-code", requestedTTL: nil, uniqueID: "x")
        #expect(plan?.ttl == 300 + BackgroundBashHold.monitorGraceSeconds)
    }

    @Test
    func `a monitor's timeout is capped at the tool's maximum`() {
        let plan = BackgroundBashHold.plan(payload: monitorPayload(#"{"command":"x","timeout_ms":99999999}"#), tool: "claude-code", requestedTTL: nil, uniqueID: "x")
        #expect(plan?.ttl == 3_600 + BackgroundBashHold.monitorGraceSeconds)
    }

    @Test
    func `a monitor's hold never exceeds the requested TTL`() {
        let plan = BackgroundBashHold.plan(payload: monitorPayload(#"{"command":"x","timeout_ms":3600000}"#), tool: "claude-code", requestedTTL: 600, uniqueID: "x")
        #expect(plan?.ttl == 600)
    }

    @Test
    func `a websocket monitor holds like a command monitor`() {
        let payload = monitorPayload(#"{"ws":{"url":"wss://example.com/events"},"timeout_ms":120000}"#)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: nil, uniqueID: "x")?.ttl == 120 + BackgroundBashHold.monitorGraceSeconds)
    }

    @Test
    func `a persistent monitor holds for the requested TTL`() {
        let payload = monitorPayload(#"{"command":"x","persistent":true}"#)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: 7_200, uniqueID: "x")?.ttl == 7_200)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: nil, uniqueID: "x")?.ttl == BackgroundBashHold.defaultTTLSeconds)
    }

    @Test
    func `another tool's payload yields no plan`() {
        let payload = data(#"{"tool_name":"Read","tool_input":{"file_path":"/tmp/x","timeout_ms":1000}}"#)
        #expect(BackgroundBashHold.plan(payload: payload, tool: "claude-code", requestedTTL: nil, uniqueID: "x") == nil)
    }

    // MARK: - Background keys

    @Test
    func `isBackgroundKey recognises bg holds only`() {
        #expect(BackgroundBashHold.isBackgroundKey("claude-code:bg-abc123"))
        #expect(!BackgroundBashHold.isBackgroundKey("claude-code:5f0c-session"))
        #expect(!BackgroundBashHold.isBackgroundKey("bg-abc123"), "no tool slot — not a key this hook places")
        #expect(!BackgroundBashHold.isBackgroundKey("hold:abc"))
    }

    // MARK: - Fresh id

    @Test
    func `freshID is short and unique`() {
        let id = BackgroundBashHold.freshID()
        #expect(id.count == 8)
        #expect(BackgroundBashHold.freshID() != BackgroundBashHold.freshID())
    }

    // MARK: - Deterministic key from tool_use_id

    private func callPayload(toolUseID: String?, sessionID: String = "sess-1", runInBackground: Bool = true, extra: [String: Any] = [:]) -> Data {
        var obj: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": sessionID,
            "tool_name": "Bash",
            "tool_input": ["command": "npm run build", "run_in_background": runInBackground],
        ]
        if let toolUseID { obj["tool_use_id"] = toolUseID }
        for (key, value) in extra {
            obj[key] = value
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test
    func `the key derives from tool_use_id, ignoring the fallback id`() {
        let a = BackgroundBashHold.plan(payload: callPayload(toolUseID: "toolu_1"), tool: "claude-code", requestedTTL: nil, uniqueID: "one")
        let b = BackgroundBashHold.plan(payload: callPayload(toolUseID: "toolu_1"), tool: "claude-code", requestedTTL: nil, uniqueID: "two")
        #expect(a?.key == b?.key, "the same tool call must key identically in every process")
        #expect(a?.key == "claude-code:bg-" + BackgroundBashHold.bindingID(toolUseID: "toolu_1"))
    }

    @Test
    func `different tool_use_ids key different holds`() {
        let a = BackgroundBashHold.plan(payload: callPayload(toolUseID: "toolu_1"), tool: "claude-code", requestedTTL: nil, uniqueID: "x")
        let b = BackgroundBashHold.plan(payload: callPayload(toolUseID: "toolu_2"), tool: "claude-code", requestedTTL: nil, uniqueID: "x")
        #expect(a?.key != b?.key)
    }

    @Test
    func `without a tool_use_id the plan falls back to the given id`() {
        let plan = BackgroundBashHold.plan(payload: callPayload(toolUseID: nil), tool: "claude-code", requestedTTL: nil, uniqueID: "fallback")
        #expect(plan?.key == "claude-code:bg-fallback")
        let emptyID = BackgroundBashHold.plan(payload: callPayload(toolUseID: ""), tool: "claude-code", requestedTTL: nil, uniqueID: "fallback")
        #expect(emptyID?.key == "claude-code:bg-fallback", "an empty tool_use_id reads as absent")
    }

    @Test
    func `bindingID is the 32-bit FNV-1a of the id, as 8 lowercase hex`() {
        // FNV-1a test vectors: the empty string and "a".
        #expect(BackgroundBashHold.bindingID(toolUseID: "") == "811c9dc5")
        #expect(BackgroundBashHold.bindingID(toolUseID: "a") == "e40c292c")
        let id = BackgroundBashHold.bindingID(toolUseID: "toolu_01GKh9jeNrf3xd9ZNikP2xsr")
        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - PostToolUse: which task a call started

    private func resultPayload(taskID: String? = "bbtqgkha5", toolUseID: String? = "toolu_1", runInBackground: Bool = true, toolName: String = "Bash") -> Data {
        var response: [String: Any] = ["stdout": "", "stderr": ""]
        if let taskID { response["backgroundTaskId"] = taskID }
        var obj: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": "sess-1",
            "tool_name": toolName,
            "tool_input": ["command": "npm run build", "run_in_background": runInBackground],
            "tool_response": response,
        ]
        if let toolUseID { obj["tool_use_id"] = toolUseID }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test
    func `a backgrounded call's post names the same hold its pre placed`() {
        let pre = BackgroundBashHold.plan(payload: callPayload(toolUseID: "toolu_1"), tool: "claude-code", requestedTTL: 3_600, uniqueID: "x")
        let task = BackgroundBashHold.startedTask(payload: resultPayload(toolUseID: "toolu_1"), tool: "claude-code", requestedTTL: 3_600)
        #expect(task?.key == pre?.key)
        #expect(task?.ttl == pre?.ttl)
        #expect(task?.taskID == "bbtqgkha5")
        #expect(task?.sessionID == "sess-1")
    }

    @Test
    func `a foreground call's post starts no task`() {
        #expect(BackgroundBashHold.startedTask(payload: resultPayload(taskID: nil, runInBackground: false), tool: "claude-code", requestedTTL: nil) == nil)
    }

    @Test
    func `a post without a backgroundTaskId starts no task`() {
        #expect(BackgroundBashHold.startedTask(payload: resultPayload(taskID: nil), tool: "claude-code", requestedTTL: nil) == nil)
        #expect(BackgroundBashHold.startedTask(payload: resultPayload(taskID: ""), tool: "claude-code", requestedTTL: nil) == nil)
    }

    @Test
    func `a monitor's post starts no task`() {
        #expect(BackgroundBashHold.startedTask(payload: resultPayload(toolName: "Monitor"), tool: "claude-code", requestedTTL: nil) == nil)
    }

    @Test
    func `a post without a session_id starts no task`() {
        let payload = data(#"{"tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"run_in_background":true},"tool_response":{"backgroundTaskId":"t1"}}"#)
        #expect(BackgroundBashHold.startedTask(payload: payload, tool: "claude-code", requestedTTL: nil) == nil)
    }

    @Test
    func `a started task's ttl defaults to the ceiling`() {
        #expect(BackgroundBashHold.startedTask(payload: resultPayload(), tool: "claude-code", requestedTTL: nil)?.ttl == BackgroundBashHold.defaultTTLSeconds)
    }

    // MARK: - The bind decision

    @Test
    func `a live shell binds the hold to its pid`() {
        let search = BackgroundBashHold.ShellSearch(pid: 4_242, snapshotIncludesCaller: true)
        #expect(BackgroundBashHold.binding(search: search, outputExists: true) == .bind(4_242))
        #expect(BackgroundBashHold.binding(search: search, outputExists: false) == .bind(4_242))
    }

    @Test
    func `no shell but an output file means the task finished`() {
        let search = BackgroundBashHold.ShellSearch(pid: nil, snapshotIncludesCaller: true)
        #expect(BackgroundBashHold.binding(search: search, outputExists: true) == .release)
    }

    @Test
    func `no shell and no output file leaves the hold to its TTL`() {
        let search = BackgroundBashHold.ShellSearch(pid: nil, snapshotIncludesCaller: true)
        #expect(BackgroundBashHold.binding(search: search, outputExists: false) == BackgroundBashHold.TaskBinding.none)
    }

    @Test
    func `the hook's own chain releases a finished task even though its stdio are pipes`() {
        // The shell is gone; the only live descendants are the hook's /bin/sh (200) and the CLI itself
        // (300), whose stdio are pipes. The caller being in the snapshot proves it is real.
        let children: [pid_t: [pid_t]] = [100: [200], 200: [300]]
        let search = BackgroundBashHold.taskShellSearch(root: 100, caller: 300, suffix: taskSuffix(), children: children) { _ in [] }
        #expect(search == BackgroundBashHold.ShellSearch(pid: nil, snapshotIncludesCaller: true))
        #expect(BackgroundBashHold.binding(search: search, outputExists: true) == .release)
    }

    @Test
    func `a failed or empty process snapshot never releases, even with the output file present`() {
        // A failed snapshot yields no children, so the caller is absent: that says nothing about the shell.
        let search = BackgroundBashHold.taskShellSearch(root: 100, caller: 300, suffix: taskSuffix(), children: [:]) { _ in [] }
        #expect(search.snapshotIncludesCaller == false)
        #expect(BackgroundBashHold.binding(search: search, outputExists: true) == BackgroundBashHold.TaskBinding.none)
    }

    @Test
    func `a live shell binds even when the snapshot is partial`() {
        let children: [pid_t: [pid_t]] = [100: [200]]
        let search = BackgroundBashHold.taskShellSearch(root: 100, caller: 300, suffix: taskSuffix(), children: children) { pid in
            pid == 200 ? [self.taskSuffix()] : []
        }
        #expect(BackgroundBashHold.binding(search: search, outputExists: true) == .bind(200))
    }

    // MARK: - Locating the shell

    private func taskSuffix() -> String {
        BackgroundBashHold.taskOutputSuffix(sessionID: "sess-1", taskID: "bbtqgkha5")
    }

    private func shellPID(root: pid_t, children: [pid_t: [pid_t]], openPaths: (pid_t) -> [String]) -> pid_t? {
        BackgroundBashHold.taskShellSearch(root: root, caller: -1, suffix: taskSuffix(), children: children, openPaths: openPaths).pid
    }

    @Test
    func `the topmost holder of the output file is the shell`() {
        // 100 is the agent; 200 is the shell; 300 is a command it runs, inheriting the same fds.
        let children: [pid_t: [pid_t]] = [100: [200, 250], 200: [300], 250: []]
        let shell = shellPID(root: 100, children: children) { pid in
            pid == 200 || pid == 300 ? ["/private/tmp/claude-501/slug\(self.taskSuffix())"] : []
        }
        #expect(shell == 200)
    }

    @Test
    func `a deeper holder is found when nothing above it holds the file`() {
        let children: [pid_t: [pid_t]] = [100: [200], 200: [300]]
        let shell = shellPID(root: 100, children: children) { pid in
            pid == 300 ? [self.taskSuffix()] : []
        }
        #expect(shell == 300)
    }

    @Test
    func `the agent itself is never the shell`() {
        let children: [pid_t: [pid_t]] = [100: [200]]
        let shell = shellPID(root: 100, children: children) { _ in [self.taskSuffix()] }
        #expect(shell == 200)
        let onlyRoot = shellPID(root: 100, children: [:]) { _ in [self.taskSuffix()] }
        #expect(onlyRoot == nil, "the root is excluded even when it holds the file")
    }

    @Test
    func `a process tree with no holder yields no shell`() {
        let children: [pid_t: [pid_t]] = [100: [200], 200: [100]]
        #expect(shellPID(root: 100, children: children) { _ in ["/tmp/other.output"] } == nil)
    }

    @Test
    func `another session's output file does not match`() {
        let children: [pid_t: [pid_t]] = [100: [200]]
        let shell = shellPID(root: 100, children: children) { _ in
            ["/tmp/claude-501/slug/other-sess/tasks/bbtqgkha5.output"]
        }
        #expect(shell == nil)
    }

    // MARK: - Output file

    @Test
    func `the output file is searched under each per-cwd directory`() {
        let found = BackgroundBashHold.taskOutputExists(
            sessionID: "sess-1",
            taskID: "bbtqgkha5",
            tempRoot: "/var/tmp",
            uid: 501,
            listDirectories: { dir in
                #expect(dir == "/var/tmp/claude-501")
                return ["-Users-me-a", "-Users-me-b"]
            },
            fileExists: { $0 == "/var/tmp/claude-501/-Users-me-b/sess-1/tasks/bbtqgkha5.output" },
        )
        #expect(found)
    }

    @Test
    func `a missing output file reads as absent`() {
        #expect(!BackgroundBashHold.taskOutputExists(sessionID: "s", taskID: "t", tempRoot: "/tmp", uid: 501, listDirectories: { _ in ["slug"] }, fileExists: { _ in false }))
    }

    @Test
    func `the temp root is CLAUDE_CODE_TMPDIR, else tmp`() {
        #expect(BackgroundBashHold.taskTempRoot(environment: ["CLAUDE_CODE_TMPDIR": "/custom"]) == "/custom")
        #expect(BackgroundBashHold.taskTempRoot(environment: ["CLAUDE_CODE_TMPDIR": ""]) == "/tmp")
        #expect(BackgroundBashHold.taskTempRoot(environment: [:]) == "/tmp")
    }

    // MARK: - Live process

    @Test
    func `the shell of a live background command is found by its output file until it exits`() throws {
        // A real child writing to a real file under a fake session's tasks dir: the libproc fd lookup,
        // the process-tree walk, and the topmost pick all run against an actual process.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adrafinil-task-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = root.appendingPathComponent("fake-session/tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let output = tasks.appendingPathComponent("bbtlive01.output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let suffix = BackgroundBashHold.taskOutputSuffix(sessionID: "fake-session", taskID: "bbtlive01")

        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try handle.close()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let shell = BackgroundBashHold.taskShellSearch(
            root: getpid(),
            caller: getpid(),
            suffix: suffix,
            children: ProcessResolver.childMap(),
            openPaths: ProcessResolver.stdioPaths(of:),
        ).pid
        #expect(shell == process.processIdentifier, "the topmost holder is the child the test spawned")

        process.terminate()
        process.waitUntilExit()
        let afterExit = BackgroundBashHold.taskShellSearch(
            root: getpid(),
            caller: getpid(),
            suffix: suffix,
            children: ProcessResolver.childMap(),
            openPaths: ProcessResolver.stdioPaths(of:),
        ).pid
        #expect(afterExit == nil, "once the shell has exited, nothing holds the file")
    }
}
