import AdrafinilShared
import AppKit
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
/// `autoInstallUpdates` off the check still runs and still answers ``availableVersion`` —
/// the Settings row and menu-bar card draw from it — but nothing downloads or installs except
/// through ``updateNow()``. There is no separate notify-only poller.
///
/// The loop ticks every ``checkInterval``; between ticks, opening the popover or waking the Mac
/// repeats the check once it is ``staleAfter`` old, and the Settings button makes one on demand.
/// Each is a single GitHub metadata request, which GitHub itself caches for a minute.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "adrafinil"

    /// The Settings row and the menu-bar card announce a release within hours of it shipping, so
    /// a fix reaches people the same day; the request is one cached metadata call.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// A check older than this is repeated when the popover opens or the Mac wakes: the loop's
    /// tick may have landed while the Mac slept, or at a launch before the network was up.
    private static let staleAfter: TimeInterval = 60 * 60

    /// The network comes back a beat after the Mac does; asking at the wake notification itself
    /// fails and leaves the next try to the loop.
    private static let wakeGrace: Duration = .seconds(20)

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
    /// wait and the post-update notice against the running bundle (a notice that outlived its
    /// version is dropped) even before `start()`.
    @ObservationIgnored private let github: TiptoeGitHub
    @ObservationIgnored private let log = Logger(
        subsystem: AdrafinilConstants.appBundleID, category: "SilentUpdates",
    )
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// When this object last asked GitHub itself. The loop's own ticks are not visible here, so
    /// this is a floor on freshness: a stale check may repeat a tick made minutes ago, at the
    /// cost of one cached metadata request.
    @ObservationIgnored private var lastCheckedAt: Date?

    /// The one metadata request in flight, shared by whoever asks while it runs.
    @ObservationIgnored private var checkInFlight: Task<Void, Never>?

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
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkAfterWake()
                }
            }
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
        await check()
        isChecking = false
        // "Nothing newer" and "couldn't reach GitHub" both leave availableVersion nil, so this
        // reassurance can be a beat optimistic offline. The loop self-corrects, and
        // onChecksFailing reports a real outage.
        checkedUpToDate = availableVersion == nil && pendingVersion == nil
    }

    /// The check the popover's appearance and the Mac's waking make, when the last one is old
    /// enough to be worth repeating. Quiet: nothing in the UI shows its progress.
    func checkIfStale() {
        // A development build does not poll GitHub on its own; the Settings button's check is
        // the one request it makes, and only when asked.
        #if !DEBUG
            if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < Self.staleAfter { return }
            Task(name: "Check for updates (stale)") { await check() }
        #endif
    }

    private func checkAfterWake() {
        Task(name: "Check for updates after wake") { [weak self] in
            try? await Task.sleep(for: Self.wakeGrace)
            self?.checkIfStale()
        }
    }

    /// One metadata request; a second caller while it runs waits for the same answer.
    private func check() async {
        if let checkInFlight {
            await checkInFlight.value
            return
        }
        let task = Task(name: "Check for updates") { [github] in
            await github.checkNow()
        }
        checkInFlight = task
        await task.value
        checkInFlight = nil
        lastCheckedAt = .now
        refresh()
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the newest release right away — the user asked,
    /// so no quiet moment is waited out and no gate is consulted. On success the app relaunches
    /// and this never returns to its caller in a meaningful way; still running a few seconds
    /// later means the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed(String(localized: "In-place updating is disabled in development builds."))
        #else
            manualPhase = .working

            // `github.updateNow()` asks GitHub itself and replaces a download that fell behind,
            // but answers a press during a running check with whatever is already held — with
            // auto-install off, nothing. So a check this object started finishes first.
            await checkInFlight?.value

            // Installs the newest release, reusing the DMG the automatic path holds when it is
            // still the newest — `false` means there was nothing newer or the download couldn't
            // be prepared.
            guard await github.updateNow() else {
                // `availableVersion` is set only by a check that reached GitHub and found an
                // installable DMG; without it there is nothing to download, whatever the network.
                manualPhase = .failed(
                    github.availableVersion == nil
                        ? String(localized: "Couldn't find a download for this update. Get it from the releases page.")
                        : String(localized: "Couldn't download the update. Check your connection, or get it from the releases page."),
                )
                refresh()
                return
            }

            // A successful swap terminates this process on its own schedule, possibly a beat
            // after the install call returns — wait it out before declaring failure.
            try? await Task.sleep(for: .seconds(4))
            refresh()
            manualPhase = .failed(String(localized: "The update couldn't be installed. Try again, or get it from the releases page."))
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
