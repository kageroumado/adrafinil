import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog
import AdrafinilShared

/// Keeps the Mac awake while an agent is working.
///
/// Two concerns, blocked together while at least one assertion is held:
///
/// 1. **Idle system sleep** is held off with a standard, reference-counted `IOPMAssertion`
///    (`kIOPMAssertPreventUserIdleSystemSleep`). The kernel releases it automatically if this
///    process dies, and it shows in `pmset -g assertions` so the user can see Adrafinil is active.
///    It does *not*, by its own header, survive a lid close.
/// 2. **Clamshell (lid-closed) sleep** is blocked with the global **`SleepDisabled`** power
///    setting, applied via `pmset -a disablesleep 1`.
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
/// helper clears it on release and again on startup (crash recovery), and the daemon re-applies
/// the blocked state on wake (see `SystemPowerMonitor`).
///
/// Not internally synchronized: `HelperXPCService` serializes every call under a lock.
final class SleepBlocker {
    private(set) var isBlocked = false

    private var assertionID: IOPMAssertionID = 0

    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "SleepBlocker")

    init() {
        // Recover from a prior instance that crashed while blocking: `disablesleep` persists
        // across process death (and reboot) until explicitly cleared.
        log.notice("init — clearing any stale disablesleep state from a prior instance")
        do {
            try setSleepDisabled(false)
            log.notice("init — disablesleep 0 (crash-recovery clear) ok")
        } catch {
            log.error("init — disablesleep clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func set(blocked: Bool) throws {
        // Intentionally not short-circuited on `blocked == isBlocked`: a repeated `set(true)`
        // re-asserts disablesleep, which the daemon relies on to recover after a wake
        // transition. Every step below is idempotent.
        log.notice("set(blocked: \(blocked, privacy: .public)) — was \(self.isBlocked, privacy: .public)")
        if blocked { try applyBlock() } else { applyUnblock() }
        isBlocked = blocked
        log.notice("set complete — isBlocked=\(self.isBlocked, privacy: .public)")
    }

    // MARK: - Compose

    private func applyBlock() throws {
        ensureIdleAssertion()
        try setSleepDisabled(true)
        log.notice("applyBlock — disablesleep set (blocks idle + clamshell sleep)")
    }

    private func applyUnblock() {
        releaseIdleAssertion()
        do {
            try setSleepDisabled(false)
            log.notice("applyUnblock — released idle assertion; disablesleep cleared")
        } catch {
            log.error("applyUnblock — disablesleep clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Idle system sleep (public assertion)

    private func ensureIdleAssertion() {
        guard assertionID == 0 else { log.debug("ensureIdleAssertion — already held (id=\(self.assertionID))"); return }
        let kr = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Adrafinil — agent active" as CFString,
            &assertionID
        )
        if kr == kIOReturnSuccess {
            log.notice("ensureIdleAssertion — created idle-sleep assertion id=\(self.assertionID)")
        } else {
            log.error("ensureIdleAssertion — IOPMAssertionCreateWithName failed: kr=0x\(String(kr, radix: 16), privacy: .public)")
        }
    }

    private func releaseIdleAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        log.notice("releaseIdleAssertion — released id=\(self.assertionID)")
        assertionID = 0
    }

    // MARK: - Clamshell sleep (global SleepDisabled via pmset)

    private func setSleepDisabled(_ disable: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "disablesleep", disable ? "1" : "0"]

        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()
        log.notice("pmset -a disablesleep \(disable ? "1" : "0", privacy: .public) exited \(task.terminationStatus, privacy: .public)")

        guard task.terminationStatus == 0 else {
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: err, encoding: .utf8) ?? "pmset exited \(task.terminationStatus)"
            throw NSError(domain: "Adrafinil.Helper.SleepBlocker", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
