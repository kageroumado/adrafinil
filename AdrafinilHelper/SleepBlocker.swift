import AdrafinilShared
import Foundation
import IOKit
import IOKit.pwr_mgt
import os
import OSLog

/// Keeps the Mac awake while an agent is working.
///
/// A thin helper-side wrapper around `SleepBlockPolicy` (in AdrafinilShared, where the
/// compose/idempotence/crash-recovery logic is unit-tested). This file owns only the two real
/// mechanisms behind the policy's seams:
///
/// 1. **Idle system sleep** — a standard, reference-counted `IOPMAssertion`
///    (`kIOPMAssertPreventUserIdleSystemSleep`). The kernel releases it automatically if this
///    process dies, and it shows in `pmset -g assertions` so the user can see Adrafinil is active.
///    It does *not*, by its own header, survive a lid close.
/// 2. **Clamshell (lid-closed) sleep** — the global **`SleepDisabled`** power setting, applied via
///    `pmset -a disablesleep 1`.
///
/// > **Why shell out to `pmset` rather than an in-process IOKit call?** Three cleaner mechanisms
/// > were each tried on a real device (macOS 26.3) and **none keep a displayless lid-closed Mac
/// > awake**:
/// > 1. Private `RootDomainUserClient` selector 12 (`kPMSetClamshellSleepState` →
/// >    `setClamShellSleepDisable`) — returns `kIOReturnSuccess`, Mac still sleeps (governs the
/// >    *external-display* clamshell-mode path, not no-display lid-close).
/// > 2. `IORegistryEntrySetCFProperty(IOPMrootDomain, "SleepDisabled", …)` — returns
/// >    `kIOReturnNotPermitted` (0xE00002E2) even as root.
/// > 3. `IOPMSetSystemPowerSetting("SleepDisabled", CFNumber(1))` (the call `pmset`'s disablesleep
/// >    path makes per-key, bound via `@_silgen_name`) — returns `kIOReturnSuccess`, `pmset -g`
/// >    still reports `SleepDisabled 0`, and the Mac **sleeps on lid close**. `pmset` does more
/// >    than this single call: it coordinates `IOPMSetPMPreferences` + activation around it.
/// >
/// > Replicating `pmset`'s full sequence in-process is fragile; `/usr/bin/pmset` is Apple's tested
/// > implementation and runs only on rare block-state flips, so the subprocess cost is a non-issue.
/// > Full investigation: `~/Developer/Research/macos-clamshell-sleep-private-api.md`.
///
/// `disablesleep` is **not** cleared on crash and can reset across a sleep/wake cycle, so the
/// policy clears it on construction (crash recovery) and again on release, and the daemon
/// re-applies the blocked state on wake (see `SystemPowerMonitor`).
///
/// **One shared instance per process.** The sleep-blocking state is machine-global — the wrong
/// thing to scope per XPC connection. `HelperListenerDelegate` owns a single `SleepBlocker` and
/// hands the *same* instance to every `HelperXPCService`, so a daemon reconnect (restart or XPC
/// interruption) reuses the existing assertion instead of minting a fresh one and orphaning the
/// old (a leaked `IOPMAssertion` the kernel only reclaims on process death). Because it's now
/// shared across connections, the policy it guards lives inside an `OSAllocatedUnfairLock` (which
/// is `Sendable` and owns its protected state), so the blocker is internally synchronized — it no
/// longer relies on each `HelperXPCService` holding a per-instance lock (which wouldn't serialize
/// across instances anyway).
final class SleepBlocker {
    /// The policy, guarded by the lock that owns it. `uncheckedState` because `SleepBlockPolicy`
    /// holds the non-`Sendable` IOKit/`pmset` mechanisms — the lock *is* the isolation that makes
    /// touching them across connections safe.
    private let policy: OSAllocatedUnfairLock<SleepBlockPolicy>
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "SleepBlocker")

    var isBlocked: Bool {
        policy.withLock { $0.isBlocked }
    }

    init() {
        log.notice("init — clearing any stale disablesleep state from a prior instance")
        // SleepBlockPolicy clears any stale clamshell block on construction (crash recovery).
        self.policy = OSAllocatedUnfairLock(
            uncheckedState: SleepBlockPolicy(idle: RealIdleAssertion(), clamshell: PMSetClamshellControl()),
        )
    }

    func set(blocked: Bool) throws {
        // `withLock`'s body is `@Sendable`, so it can't capture `self`; bind the (Sendable) Logger
        // locally and capture that, keeping the before/after logging inside the critical section.
        let log = log
        try policy.withLock { policy in
            // Read into locals before logging: the Logger interpolation is an escaping autoclosure,
            // which can't capture the `inout policy`.
            let was = policy.isBlocked
            log.notice("set(blocked: \(blocked, privacy: .public)) — was \(was, privacy: .public)")
            try policy.set(blocked: blocked)
            let now = policy.isBlocked
            log.notice("set complete — isBlocked=\(now, privacy: .public)")
        }
    }
}

/// The standard, reference-counted idle-sleep assertion. `acquire()` is idempotent — a second call
/// while already held is a no-op (`SleepBlockPolicy` relies on this for wake re-assertion).
private final class RealIdleAssertion: IdleSleepAsserting {
    private var assertionID: IOPMAssertionID = 0
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "SleepBlocker")

    var isHeld: Bool {
        assertionID != 0
    }

    /// Defensive: if a `SleepBlocker` is ever torn down while still holding the assertion, release
    /// it here rather than leaking it until process death. With the shared-instance design this
    /// should only ever fire at process exit (where the kernel would reclaim it anyway), but it
    /// makes any future per-instance use leak-free by construction.
    deinit { release() }

    func acquire() {
        guard assertionID == 0 else {
            log.debug("ensureIdleAssertion — already held (id=\(self.assertionID))")
            return
        }
        let kr = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Adrafinil: agent active" as CFString,
            &assertionID,
        )
        if kr == kIOReturnSuccess {
            log.notice("ensureIdleAssertion — created idle-sleep assertion id=\(self.assertionID)")
        } else {
            log.error("ensureIdleAssertion — IOPMAssertionCreateWithName failed: kr=0x\(String(kr, radix: 16), privacy: .public)")
        }
    }

    func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        log.notice("releaseIdleAssertion — released id=\(self.assertionID)")
        assertionID = 0
    }
}

/// Clamshell (lid-closed) sleep via the global `SleepDisabled` setting, applied with
/// `pmset -a disablesleep`. Throws if `pmset` exits non-zero (surfaced to the daemon over XPC on
/// block; best-effort on unblock).
private final class PMSetClamshellControl: ClamshellSleepControlling {
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "SleepBlocker")

    func setDisabled(_ disabled: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]

        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()
        log.notice("pmset -a disablesleep \(disabled ? "1" : "0", privacy: .public) exited \(task.terminationStatus, privacy: .public)")

        guard task.terminationStatus == 0 else {
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: err, encoding: .utf8) ?? "pmset exited \(task.terminationStatus)"
            throw NSError(
                domain: "Adrafinil.Helper.SleepBlocker",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg],
            )
        }
    }
}
