import AdrafinilShared
import Foundation
import Observation
import os
import Tiptoe
import TiptoeGitHub

/// The app's updater: downloads from GitHub Releases, verifies, and swaps the bundle in place —
/// silently when the user allows it, on an explicit Update Now otherwise.
///
/// The heavy lifting is [Tiptoe](https://github.com/artginzburg/Tiptoe) over mxcl/AppUpdater:
/// AppUpdater checks the release, downloads the DMG, and verifies the Team ID against the running
/// app; Tiptoe decides *when* the swap may run. Installing on the app's own is normally the awkward
/// part — the swap restarts the app — and here it is worse than awkward: restarting while the
/// daemon holds assertions would let the Mac sleep at exactly the moment somebody's agent is
/// mid-run. So the automatic path waits for two separate things: Tiptoe watches for the Mac to go
/// quiet, and the gate below asks the daemon for the half Tiptoe cannot know.
///
/// The gate is a veto, not a preference: Tiptoe's own patience relaxes over days, this never does.
///
/// With `autoInstallUpdates` off, the daily check loop never runs. `UpdateCheckService` still
/// notifies (Settings row, menu-bar card), and ``updateNow()`` performs the same
/// download-verify-swap on demand.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "adrafinil"

    /// Matches `UpdateCheckService`'s own cadence — this app has never wanted to poll GitHub more
    /// often than once a day, and finding an update sooner would not install it sooner anyway.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    /// Progress of a user-initiated Update Now, for the Settings row. A successful install
    /// replaces the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The version the automatic path has downloaded and is holding for a quiet moment, if any.
    /// Refreshed by ``refreshPending()`` — Tiptoe itself is not observable.
    private(set) var pendingVersion: String?

    /// The version a silent (or manual) install brought us to, until the user has seen the
    /// "what's new" notice. Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// The long-lived automatic updater: daily check loop + quiet-moment install. Created up
    /// front so its `Tiptoe` reconciles the recorded wait (and surfaces `justUpdatedTo`) even
    /// when auto-install is off; the check loop only runs after `start()`.
    @ObservationIgnored private let github: TiptoeGitHub
    @ObservationIgnored private var autoRunning = false
    @ObservationIgnored private let log = Logger(
        subsystem: AdrafinilConstants.appBundleID, category: "SilentUpdates",
    )

    private init() {
        github = TiptoeGitHub(owner: Self.owner, repo: Self.repo, checkInterval: Self.checkInterval)
            .gate("agents are being kept awake") { await Self.nothingIsBeingKeptAwake() }
        justUpdatedVersion = github.tiptoe.justUpdatedTo
    }

    // MARK: - Automatic installs

    /// Called once at launch (release, post-setup) with the user's setting.
    func start(autoInstall: Bool) {
        if autoInstall { startAuto() }
    }

    /// Reacts to the Settings toggle. Turning auto off stops the check loop and the quiet-moment
    /// watcher; a DMG already downloaded stays downloaded but installs only via ``updateNow()``.
    func setAutoInstall(_ enabled: Bool) {
        enabled ? startAuto() : stopAuto()
    }

    private func startAuto() {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode. The debug control panel exercises the UI states directly.
        #if !DEBUG
            guard !autoRunning else { return }
            autoRunning = true
            github.start()
        #endif
    }

    private func stopAuto() {
        guard autoRunning else { return }
        autoRunning = false
        github.stop()
        refreshPending()
    }

    /// Copies Tiptoe's pending state into the observable ``pendingVersion``. Called when the
    /// Settings tab appears and after update actions — Tiptoe has no change callback for it.
    func refreshPending() {
        #if DEBUG
            if debugOwnsPending { return } // the debug panel is driving the scenario
        #endif
        pendingVersion = github.tiptoe.pending?.version
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the newest release right away — the user asked.
    /// On success the app relaunches and this never returns to its caller in a meaningful way;
    /// still running a few seconds later means the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed("In-place updating is disabled in development builds.")
        #else
            manualPhase = .working

            if autoRunning, github.tiptoe.pending != nil {
                // The automatic path already downloaded and verified it — just stop waiting.
                await github.tiptoe.installNow().value
            } else {
                // Auto is off (its instance is stopped, and a stopped TiptoeGitHub refuses
                // `checkNow`), so run the download through a one-shot instance. It shares
                // Tiptoe's on-disk store, so a successful install still records "just updated"
                // for the relaunch to announce.
                let oneShot = TiptoeGitHub(owner: Self.owner, repo: Self.repo)
                await oneShot.checkNow()
                guard oneShot.tiptoe.pending != nil else {
                    manualPhase = .failed("Couldn't download the update. Check your connection, or get it from the releases page.")
                    return
                }
                await oneShot.tiptoe.installNow().value
            }

            // A successful swap terminates this process on its own schedule, possibly a beat
            // after the install call returns — wait it out before declaring failure.
            try? await Task.sleep(for: .seconds(4))
            refreshPending()
            manualPhase = .failed("The update couldn't be installed. Try again, or get it from the releases page.")
        #endif
    }

    /// The user has seen the post-update notice.
    func acknowledgeUpdate() {
        justUpdatedVersion = nil
        github.tiptoe.acknowledge()
    }

    // MARK: - The gate

    /// The daemon owns the assertion registry, so this is a real XPC round trip rather than a glance
    /// at cached state — deliberately, since a stale "nothing running" is exactly the answer that
    /// would restart the app under a working agent.
    ///
    /// An unreachable daemon answers "no". The app cannot tell whether anything is being kept awake,
    /// and an update is never so urgent that it is worth guessing.
    private static func nothingIsBeingKeptAwake() async -> Bool {
        guard let status = try? await DaemonClient.shared.fetchStatus() else { return false }
        return !status.isBlocking && status.assertions.isEmpty
    }

    #if DEBUG
        /// While the debug panel drives `pendingVersion`, `refreshPending()` must not overwrite it
        /// with the (empty) real Tiptoe state when the Settings tab appears.
        @ObservationIgnored private var debugOwnsPending = false

        /// Drive the Settings row's states from the debug control panel without any network.
        func debugSet(pending: String?) {
            debugOwnsPending = pending != nil
            pendingVersion = pending
        }

        func debugSet(manualPhase: ManualPhase) {
            self.manualPhase = manualPhase
        }
    #endif
}
