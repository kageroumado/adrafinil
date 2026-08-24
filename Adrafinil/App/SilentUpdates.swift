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
/// One check loop serves both modes (Tiptoe ≥ 1.1's `installsAutomatically`): with
/// `autoInstallUpdates` off the daily check still runs and still answers ``availableVersion`` —
/// the Settings row and menu-bar card draw from it — but nothing downloads or installs except
/// through ``updateNow()``. This is the single daily request to GitHub; there is no separate
/// notify-only poller.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "adrafinil"

    /// This app has never wanted to poll GitHub more often than once a day — finding an update
    /// sooner would not install it sooner anyway.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    /// Progress of a user-initiated Update Now, for the Settings row. A successful install
    /// replaces the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The newest published version when it is newer than the running app, from the check loop —
    /// in both modes, downloaded or not. Refreshed by ``refresh()`` — Tiptoe itself is not
    /// observable.
    private(set) var availableVersion: String?

    /// The version the automatic path has downloaded and is holding for a quiet moment, if any.
    /// A stronger claim than ``availableVersion`` (downloaded and verified, not merely published);
    /// refreshed by ``refresh()``.
    private(set) var pendingVersion: String?

    /// True while a user-initiated check is in flight (drives the Settings button's state).
    private(set) var isChecking = false

    /// Set after a manual check that found no newer version, so the button can briefly confirm
    /// "You're up to date". Reset when a new check starts.
    private(set) var checkedUpToDate = false

    /// The version a silent (or manual) install brought us to, until the user has seen the
    /// "what's new" notice. Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// The one long-lived updater: daily check loop, `availableVersion`, and the quiet-moment
    /// install when the mode allows it. Created up front so its `Tiptoe` reconciles the recorded
    /// wait (and surfaces `justUpdatedTo`) even before `start()`.
    @ObservationIgnored private let github: TiptoeGitHub
    @ObservationIgnored private let log = Logger(
        subsystem: AdrafinilConstants.appBundleID, category: "SilentUpdates",
    )

    private init() {
        // Notify-only until `start()` applies the user's real setting — which never happens in
        // DEBUG, so a development build's manual "Check for updates" stays a metadata request
        // and can't download a DMG on the side.
        github = TiptoeGitHub(owner: Self.owner, repo: Self.repo, checkInterval: Self.checkInterval)
            .gate("agents are being kept awake") { await Self.nothingIsBeingKeptAwake() }
            .installsAutomatically(false)
        github.onChecksFailing = { [log] error in
            log.error("update checks have been failing: \(error.localizedDescription, privacy: .public)")
        }
        justUpdatedVersion = github.tiptoe.justUpdatedTo
    }

    // MARK: - The check loop

    /// Called once at launch (release, post-setup) with the user's setting. The loop always runs;
    /// the setting only decides whether a found update is downloaded and installed at a quiet
    /// moment or merely reported.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode. The debug control panel exercises the UI states directly.
        #if !DEBUG
            github.installsAutomatically(autoInstall).start()
        #endif
    }

    /// Reacts to the Settings toggle. Turning auto off keeps the check loop (and
    /// ``availableVersion``) running but downloads and installs nothing; a DMG already downloaded
    /// stays downloaded and installs only via ``updateNow()``. Turning it on checks right away.
    func setAutoInstall(_ enabled: Bool) {
        #if !DEBUG
            github.installsAutomatically(enabled)
        #endif
    }

    /// Copies Tiptoe's state into the observable properties. Called when the Settings tab
    /// appears, on the status model's heartbeat, and after update actions — Tiptoe has no
    /// change callback.
    func refresh() {
        #if DEBUG
            if debugOwnsPending { return } // the debug panel is driving the scenario
        #endif
        pendingVersion = github.tiptoe.pending?.version
        availableVersion = github.availableVersion
    }

    /// A user-initiated check, for the Settings button: same request the loop makes, off-schedule.
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        checkedUpToDate = false
        await github.checkNow()
        isChecking = false
        refresh()
        // "Nothing newer" and "couldn't reach GitHub" both leave availableVersion nil, so this
        // reassurance can be a beat optimistic offline. The daily loop self-corrects, and
        // onChecksFailing reports a real outage.
        checkedUpToDate = availableVersion == nil && pendingVersion == nil
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the newest release right away — the user asked,
    /// so no quiet moment is waited out and no gate is consulted. On success the app relaunches
    /// and this never returns to its caller in a meaningful way; still running a few seconds
    /// later means the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed("In-place updating is disabled in development builds.")
        #else
            manualPhase = .working

            // Installs the DMG the automatic path already holds, or downloads and verifies one
            // now — `false` means there was nothing newer or the download couldn't be prepared.
            guard await github.updateNow() else {
                manualPhase = .failed("Couldn't download the update. Check your connection, or get it from the releases page.")
                return
            }

            // A successful swap terminates this process on its own schedule, possibly a beat
            // after the install call returns — wait it out before declaring failure.
            try? await Task.sleep(for: .seconds(4))
            refresh()
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
        /// While the debug panel drives `pendingVersion`, `refresh()` must not overwrite it
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
