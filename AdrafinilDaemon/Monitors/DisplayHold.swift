import AdrafinilShared
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OSLog

/// The daemon-owned display assertion for display-class holds (`Assertion.holdsDisplay`).
///
/// Lives in the daemon, not the privileged helper: `PreventUserIdleDisplaySleep` needs no root,
/// and the helper's root surface stays minimal — nothing is added to it that doesn't require it.
/// The assertion is idempotent to set, released on deinit, and kernel-reclaimed if the daemon
/// crashes, so a stale display hold cannot outlive its process.
///
/// Holding is not enough on its own: an IOPM assertion only prevents *future* display sleep. If
/// the panel is already dark when the hold is raised, the agent behind it stays blind — when the
/// display sleeps, every app's accessibility tree collapses to the bare application element — so
/// `set(held: true)` also wakes the display via `IOPMAssertionDeclareUserActivity`, the one call
/// that actually relights it (`caffeinate -d` does not). The returned assertion id is reused
/// across wakes per the IOPMLib contract.
@MainActor
final class DisplayHold {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "DisplayHold")

    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false
    /// Reused across `IOPMAssertionDeclareUserActivity` calls, as its contract asks: pass the
    /// previous id back in and the system refreshes that assertion instead of minting anew.
    private var userActivityID: IOPMAssertionID = 0

    /// Raises or drops the display assertion. Idempotent — the 60s reconcile re-calls this with
    /// the current desired state, mirroring the helper's clamshell re-apply philosophy: if the
    /// assertion was lost (sleep/wake edge, IOKit hiccup), the reconcile restores it.
    func set(held wanted: Bool) {
        if wanted, !isHeld {
            // Raw string: Apple defines kIOPMAssertionTypePreventUserIdleDisplaySleep as a CFSTR
            // macro that does not import into Swift.
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                // ASCII only: `pmset -g assertions` renders non-ASCII in assertion names as `?`.
                "Adrafinil display-class hold - an agent is reading the screen" as CFString,
                &assertionID,
            )
            guard result == kIOReturnSuccess else {
                log.error("display assertion failed: IOReturn \(result, privacy: .public)")
                return
            }
            isHeld = true
            log.notice("display hold raised (assertion \(self.assertionID, privacy: .public))")
            wakeDisplayIfAsleep()
        } else if !wanted, isHeld {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHeld = false
            log.notice("display hold dropped")
        } else if wanted {
            // Already held — treat the reconcile as a chance to relight a panel that went dark
            // through a path the assertion doesn't govern (e.g. a system sleep/wake cycle; the
            // panel does not necessarily relight on its own).
            wakeDisplayIfAsleep()
        }
    }

    /// Wakes the display when it is asleep. A display assertion prevents future sleep only;
    /// without this, "acquire display" while dark would leave the agent blind until something
    /// else woke the panel. Safe against the lock screen: lock is not sleep, and the wake
    /// relights the locked screen without dismissing or touching the lock UI.
    private func wakeDisplayIfAsleep() {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        let result = IOPMAssertionDeclareUserActivity(
            "Adrafinil display-class hold wake" as CFString,
            kIOPMUserActiveLocal,
            &userActivityID,
        )
        if result == kIOReturnSuccess {
            log.notice("display woken for display-class hold")
        } else {
            log.error("display wake failed: IOReturn \(result, privacy: .public)")
        }
    }

    /// True when the machine's only display is a lid-closed built-in panel — a display-class hold
    /// is meaningless there (nothing can relight a closed lid) and the caller should know its
    /// agent will be blind. External and virtual displays count as real targets.
    nonisolated static func onlyDisplayIsClosedBuiltIn(lidClosed: Bool) -> Bool {
        guard lidClosed else { return false }
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &displayCount) == .success else {
            return false
        }
        let externalCount = displays.prefix(Int(displayCount)).count { CGDisplayIsBuiltin($0) == 0 }
        return externalCount == 0
    }

    isolated deinit {
        if isHeld { IOPMAssertionRelease(assertionID) }
    }
}
