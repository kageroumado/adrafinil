import Darwin
import Foundation

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
        while pid > 1, depth < 16 {
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
        for i in 0 ..< min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0, let path = path(of: pid) else { continue }
            result.append((pid, (path as NSString).lastPathComponent, path))
        }
        return result
    }

    /// Resolves the live PID of a gateway/daemon-style agent from its pid-file (see
    /// `AgentKind.gatewayPIDFileRelativePath`). Accepts either a bare integer or a JSON object with a
    /// `"pid"` field — Hermes writes `{"pid": 1006, "kind": "hermes-gateway", …}`. Returns the PID
    /// only if it parses *and* the process is currently alive; otherwise `-1` (the caller then asks
    /// the daemon not to process-watch, exactly as with an unresolved agent). Guarding on liveness
    /// keeps a stale pid-file (gateway exited without cleaning up) from binding a hold to a dead or,
    /// worse, recycled PID.
    public static func gatewayPID(pidFilePath: String) -> pid_t {
        guard let data = FileManager.default.contents(atPath: pidFilePath) else { return -1 }
        var pid: pid_t = -1
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = obj["pid"] as? Int {
            pid = pid_t(n)
        } else if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let n = Int32(text) {
            pid = n
        }
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return -1 }
        return pid
    }

    /// Resolves a live gateway PID checking the default pid-file **and** any per-profile pid-files.
    /// Hermes runs one gateway per profile — named profiles live at `<home>/.hermes/profiles/<name>/`,
    /// each a full home writing its own `gateway.pid` — and the desktop app is just a UI launcher over
    /// one of those gateways. Relying on the single default path would miss a profile gateway (and the
    /// desktop's), degrading the hold to the end-hook + 24h backstop. This mirrors Hermes' own
    /// `find_gateway_pids` discovery. Prefers the default profile, then the first live named profile;
    /// returns `-1` if none is alive.
    ///
    /// - Parameters:
    ///   - homeRoot: the user's home directory (e.g. `NSHomeDirectory()`).
    ///   - pidFileRelativePath: home-relative path of the default pid-file, `<hermesDir>/<filename>`
    ///     (e.g. `.hermes/gateway.pid`). The profiles glob is derived as `<hermesDir>/profiles/*/<filename>`.
    public static func gatewayPID(homeRoot: String, pidFileRelativePath: String) -> pid_t {
        let defaultPID = gatewayPID(pidFilePath: "\(homeRoot)/\(pidFileRelativePath)")
        if defaultPID > 0 { return defaultPID }

        let rel = pidFileRelativePath as NSString
        let hermesDir = rel.deletingLastPathComponent // ".hermes"
        let pidFilename = rel.lastPathComponent // "gateway.pid"
        let profilesDir = "\(homeRoot)/\(hermesDir)/profiles"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return -1 }
        for name in names.sorted() {
            let pid = gatewayPID(pidFilePath: "\(profilesDir)/\(name)/\(pidFilename)")
            if pid > 0 { return pid }
        }
        return -1
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN); the macro isn't visible to Swift.
    private static let maxPathSize = 4 * 1_024

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

    /// Maps each parent PID to its direct child PIDs, from a single `KERN_PROC_ALL` kernel snapshot —
    /// the same source `ps`/`pgrep -P` use. Process-tree walks build on this because
    /// `proc_listchildpids` is unreliable on current macOS (verified on 26.5: returns truncated/garbage
    /// byte counts, so children are missed). Best-effort: a process spawned between the size and fetch
    /// calls may be absent until the next snapshot — fine for a periodic sweep.
    public static func childMap() -> [pid_t: [pid_t]] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Slack: KERN_PROC_ALL is racy, so allow for processes appearing after the size probe.
        size += size / 8 + MemoryLayout<kinfo_proc>.stride * 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let count = min(size / MemoryLayout<kinfo_proc>.stride, procs.count)
        var map: [pid_t: [pid_t]] = [:]
        for i in 0 ..< count {
            let pid = procs[i].kp_proc.p_pid
            let ppid = procs[i].kp_eproc.e_ppid
            if pid > 0 { map[ppid, default: []].append(pid) }
        }
        return map
    }

    /// The argument vector of a process via `sysctl(KERN_PROCARGS2)`, or nil if it can't be read
    /// (permission, or the process exited). This is how interpreter-hosted agents are identified: a
    /// Hermes backend runs as a generic `python -m hermes_cli.main gateway run`, so its *executable*
    /// path is `python` — only the argv reveals what it is.
    ///
    /// `KERN_PROCARGS2` returns a packed blob: a leading `int argc`, the NUL-terminated executable
    /// path, alignment padding NULs, then `argc` NUL-terminated argument strings, then the
    /// environment. We parse out exactly the `argc` argv strings (stopping before the environment, so
    /// an env var that happens to contain a marker can't cause a false match).
    public static func arguments(of pid: pid_t) -> [String]? {
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buf = [UInt8](repeating: 0, count: size)
        let rc = buf.withUnsafeMutableBufferPointer { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard rc == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        // Skip the executable path and the alignment NULs that follow it.
        while i < size && buf[i] != 0 {
            i += 1
        }
        while i < size && buf[i] == 0 {
            i += 1
        }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        var tokenStart = i
        while i < size && args.count < Int(argc) {
            if buf[i] == 0 {
                args.append(String(decoding: buf[tokenStart ..< i], as: UTF8.self))
                tokenStart = i + 1
            }
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    /// Cumulative user+system CPU seconds for a single PID, or nil if it can't be read (gone).
    public static func cpuTime(of pid: pid_t) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return TimeInterval(info.pti_total_user + info.pti_total_system) * machTickSeconds
    }

    /// Seconds per unit of `proc_taskinfo`'s `pti_total_user`/`pti_total_system`. Those fields are in
    /// **mach absolute-time ticks**, not nanoseconds — on Apple Silicon one tick is ~41.7 ns (a 24 MHz
    /// timebase), so a naïve `/1e9` under-reports CPU by ~41.7×, dragging a pinned core down to ~2.4%
    /// and below any sane idle threshold. Convert through `mach_timebase_info`: on Intel numer==denom==1
    /// (this collapses to the 1e-9 the old code assumed); on arm64 numer/denom ≈ 125/3 supplies the
    /// real scale. Cached: the timebase is fixed for the life of the process.
    private static let machTickSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        guard mach_timebase_info(&tb) == KERN_SUCCESS, tb.numer != 0, tb.denom != 0 else { return 1e-9 }
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()

    /// Cumulative CPU seconds for `rootPID` plus every descendant, walking `childMap` (a single
    /// `KERN_PROC_ALL` snapshot from `childMap()`). Summing the tree — not just the root — is what
    /// keeps a long tool call active in the reading: the agent process waits while a busy child does
    /// the work. Returns nil only if the root itself is unreadable (gone).
    public static func treeCPUTime(rootPID: pid_t, childMap: [pid_t: [pid_t]]) -> TimeInterval? {
        guard let rootCPU = cpuTime(of: rootPID) else { return nil }
        var total = rootCPU
        var seen: Set<pid_t> = [rootPID]
        var stack = childMap[rootPID] ?? []
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let t = cpuTime(of: pid) { total += t }
            stack.append(contentsOf: childMap[pid] ?? [])
        }
        return total
    }

    /// Whether `rootPID` or any descendant holds an **ESTABLISHED TCP connection to a non-loopback
    /// host** — a best-effort proxy for "waiting on a server". An agent blocked on a model-API
    /// response burns near-zero local CPU but has real work in flight; the idle-release uses this to
    /// avoid sleeping the Mac mid-request during server-side "thinking". Loopback connections (e.g.
    /// to local MCP servers) are excluded, so an otherwise-idle process with only local keep-alives
    /// still releases. Trade-off: a lingering *remote* keep-alive can delay release until the TTL or
    /// max-age backstop — deliberately erring toward never cutting a real request short. Best-effort:
    /// PIDs whose fd table we can't read are skipped.
    public static func treeHasRemoteConnection(rootPID: pid_t, childMap: [pid_t: [pid_t]]) -> Bool {
        var seen: Set<pid_t> = []
        var stack = [rootPID]
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if pidHasRemoteConnection(pid) { return true }
            stack.append(contentsOf: childMap[pid] ?? [])
        }
        return false
    }

    private static func pidHasRemoteConnection(_ pid: pid_t) -> Bool {
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(probe) / stride + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * stride))
        guard written > 0 else { return false }
        let count = min(Int(written) / stride, fds.count)
        for i in 0 ..< count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) else { continue }
            let ini = tcp.tcpsi_ini
            guard ini.insi_fport != 0 else { continue } // has a foreign endpoint
            if !foreignIsLoopback(ini) { return true }
        }
        return false
    }

    /// Whether an `in_sockinfo`'s *foreign* address is loopback (127.0.0.0/8 or `::1`).
    private static func foreignIsLoopback(_ ini: in_sockinfo) -> Bool {
        // insi_vflag bit 0x1 = IPv4 (INI_IPV4), 0x2 = IPv6 (INI_IPV6).
        if ini.insi_vflag & 0x1 != 0 {
            // IPv4 foreign address in network byte order; the first octet is the low byte. 127.x = loopback.
            let addr = ini.insi_faddr.ina_46.i46a_addr4.s_addr
            return UInt8(addr & 0xFF) == 127
        }
        var addr = ini.insi_faddr.ina_6
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        guard bytes.count == 16 else { return false }
        return bytes[0 ..< 15].allSatisfy { $0 == 0 } && bytes[15] == 1
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
