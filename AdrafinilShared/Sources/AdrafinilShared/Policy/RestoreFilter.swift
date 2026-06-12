import Darwin
import Foundation

/// Validates assertions restored from `state.json` at daemon startup.
///
/// The state file survives reboots and crashes, but the *processes* behind its assertions don't:
/// after a reboot every stored PID is stale and densely recycled — a stored pid can name a live,
/// busy system process, which the CPU-idle sweep then reads as "agent working" and pins
/// `disablesleep` for up to the 24-hour backstop (the bag-cook scenario the cutouts exist to
/// prevent). So a restored assertion is kept only when it was acquired during the current boot
/// AND its PID still resolves to a plausibly-matching executable.
public enum RestoreFilter {
    public struct Outcome {
        public let kept: [Assertion]
        public let dropped: [Assertion]
    }

    /// - Parameters:
    ///   - bootTime: kernel boot time; nil skips the reboot check (fail-open: the PID checks
    ///     still apply).
    ///   - pathOf: executable path for a live PID, nil when the process is gone.
    public static func partition(
        _ restored: [Assertion],
        bootTime: Date?,
        pathOf: (pid_t) -> String?,
    ) -> Outcome {
        var kept: [Assertion] = []
        var dropped: [Assertion] = []
        for assertion in restored {
            if let bootTime, assertion.acquiredAt < bootTime {
                dropped.append(assertion)
                continue
            }
            if assertion.pid > 0 {
                guard let path = pathOf(assertion.pid),
                      executablePlausiblyMatches(storedName: assertion.processName, currentPath: path) else {
                    dropped.append(assertion)
                    continue
                }
            }
            kept.append(assertion)
        }
        return Outcome(kept: kept, dropped: dropped)
    }

    /// Whether a live executable path plausibly belongs to the process the assertion was stored
    /// for. Exact comparison is impossible: the stored `processName` may be a tool label
    /// ("claude-code") while the binary is `claude` — or even a versioned basename like `2.1.156`
    /// under a `claude/versions/` directory. So the check is containment between the stored name
    /// and each path component, in either direction, ignoring trivially short components. A false
    /// positive merely defers to the CPU-idle sweep; a recycled PID pointing at an unrelated
    /// binary (`mdworker`, `WindowServer`) is dropped.
    static func executablePlausiblyMatches(storedName: String, currentPath: String) -> Bool {
        let stored = storedName.lowercased()
        guard stored.count >= 3 else { return true }
        return (currentPath as NSString).pathComponents.contains { component in
            let c = component.lowercased()
            guard c.count >= 3 else { return false }
            return stored.contains(c) || c.contains(stored)
        }
    }

    /// Kernel boot time (`kern.boottime`), or nil if the sysctl fails.
    public static func systemBootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
