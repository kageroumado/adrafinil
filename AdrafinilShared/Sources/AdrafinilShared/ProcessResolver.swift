import Foundation
import Darwin

/// Process-tree helpers shared by the CLI (to find which agent owns an `acquire`) and the
/// daemon (to sweep for running agents).
///
/// The CLI is invoked from a hook command, typically as `agent → /bin/sh -c "adrafinil …" → adrafinil`.
/// `getppid()` is therefore the *shell*, which exits the instant `adrafinil` returns. Watching that
/// PID for exit would force-release the assertion immediately — while the agent is still working.
/// `owningAgentPID` walks up the parent chain to the real agent process so the daemon can watch the
/// process that actually matters.
public enum ProcessResolver {

    /// Walks up the parent chain from this process looking for an agent executable. Returns that
    /// PID, or `-1` if none is found (in which case the daemon must not process-watch, to avoid a
    /// premature release).
    public static func owningAgentPID(binaryNames: Set<String>) -> pid_t {
        var pid = getppid()
        var depth = 0
        while pid > 1 && depth < 16 {
            if let path = path(of: pid), pathMatchesAgent(path, names: binaryNames) {
                return pid
            }
            let parent = parentPID(of: pid)
            guard parent > 0, parent != pid else { break }
            pid = parent
            depth += 1
        }
        return -1
    }

    /// Whether an executable path belongs to a known agent. Matches if **any path component** is in
    /// `names`, not just the basename — agents are commonly installed under versioned paths whose
    /// basename is a version string (e.g. `~/.local/share/claude/versions/2.1.156`, whose basename
    /// `2.1.156` matches nothing, but whose component `claude` does). Component matching against the
    /// specific agent-name set (claude, codex, gemini, …) is safe: those names don't collide with
    /// generic path segments. Basename-only matching missed Claude entirely (pid resolved to -1),
    /// leaving its assertion unwatchable.
    public static func pathMatchesAgent(_ path: String, names: Set<String>) -> Bool {
        (path as NSString).pathComponents.contains { names.contains($0) }
    }

    /// All currently running processes as `(pid, basename, fullPath)`. Used by the daemon's periodic
    /// sniff sweep. Best-effort: processes we cannot read are skipped.
    public static func runningProcesses() -> [(pid: pid_t, name: String, path: String)] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride

        var result: [(pid_t, String, String)] = []
        result.reserveCapacity(count)
        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0, let path = path(of: pid) else { continue }
            result.append((pid, (path as NSString).lastPathComponent, path))
        }
        return result
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN); the macro isn't visible to Swift.
    private static let maxPathSize = 4 * 1024

    /// Full executable path for a PID, or nil if it can't be read.
    public static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: maxPathSize)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let path = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// Executable basename for a PID, or nil if it can't be read.
    public static func name(of pid: pid_t) -> String? {
        guard let p = path(of: pid) else { return nil }
        return (p as NSString).lastPathComponent
    }

    /// Parent PID via `sysctl(KERN_PROC_PID)`. Returns `-1` on failure.
    public static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard r == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}
