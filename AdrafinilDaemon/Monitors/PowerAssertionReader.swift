import Foundation
import IOKit

/// Reads the system power-assertion table — the same data `pmset -g assertions` shows — to find
/// which processes currently hold an assertion that keeps the **whole system** awake.
///
/// Why this exists: a coding agent that is "thinking" computes on the server while its local process
/// is near-idle (just a spinner), so a CPU-rate idle check can't tell working-but-thinking apart from
/// abandoned — and would false-release the hold mid-turn, sleeping a lid-closed Mac and dropping the
/// in-flight model connection. But agents already *declare* "I'm working" by holding their own
/// `IOPMAssertion`: Claude Code spawns `caffeinate -i` exactly while `isLoading && !waitingForApproval`
/// (verified — a `caffeinate -i -t 300` child of `claude` holding `PreventUserIdleSystemSleep`).
/// Mirroring that declared intent is the authoritative "still working" signal. `caffeinate -i` blocks
/// only *idle* sleep, not clamshell — so reading it and extending it to the closed lid is precisely
/// Adrafinil's value-add, not a duplicate.
///
/// `IOPMCopyAssertionsByProcess` is IOKit SPI (no public header); it's bound by symbol below, matching
/// the project's existing private-power-API pattern (see `SleepBlocker`).
enum PowerAssertionReader {
    /// `AssertType` values that keep the entire system awake. Display-only types
    /// (`PreventUserIdleDisplaySleep`) are deliberately excluded — they don't keep a lid-closed,
    /// displayless Mac running, so they don't mean "agent working" for our purposes.
    private static let systemSleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",  // caffeinate -i — the common agent signal
        "PreventSystemSleep",          // caffeinate -s
        "NoIdleSleepAssertion",        // legacy alias
    ]

    /// PIDs currently holding a system-sleep-preventing assertion. Empty on failure or none — both
    /// mean "no extra keep-alive signal", so the CPU-rate path alone governs the release decision.
    ///
    /// Note this is system-wide (it includes `powerd`, `coreaudiod`, etc.), so callers MUST scope it
    /// to a specific agent's process tree — a global "is anything blocking sleep" is almost always
    /// true and would pin the Mac awake forever.
    static func pidsPreventingSystemSleep() -> Set<pid_t> {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let raw = out?.takeRetainedValue(),
              let byPID = raw as NSDictionary as? [Int: [[String: Any]]] else { return [] }

        var pids: Set<pid_t> = []
        for (pid, assertions) in byPID where pid > 0 {
            let asserts = assertions.contains { assertion in
                (assertion["AssertType"] as? String).map(systemSleepPreventingTypes.contains) ?? false
            }
            if asserts { pids.insert(pid_t(pid)) }
        }
        return pids
    }
}

/// IOKit SPI: fills `*assertionsByPID` with a `+1` dictionary mapping each holder PID (CFNumber) to a
/// CFArray of assertion dictionaries (keys `AssertType`, `AssertName`, …). Caller owns the dictionary.
@_silgen_name("IOPMCopyAssertionsByProcess")
private func IOPMCopyAssertionsByProcess(_ assertionsByPID: UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> IOReturn
