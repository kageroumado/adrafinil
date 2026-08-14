import AdrafinilShared
import Foundation
import TiptoeGitHub

/// Updates that install themselves, and never while an agent is being kept awake.
///
/// Adrafinil could already tell you a new version existed; getting it was a manual download, so
/// installs drift. Installing on the app's own is normally the awkward part — the swap restarts the
/// app — and here it is worse than awkward: restarting while the daemon holds assertions would let
/// the Mac sleep at exactly the moment somebody's agent is mid-run.
///
/// So the swap waits for two separate things. [Tiptoe](https://github.com/artginzburg/Tiptoe)
/// watches for the Mac to go quiet — no input for a while, no window of ours with unsaved work —
/// and asks the gate below for the half it cannot know. The download itself is invisible and needs
/// no permission from anybody; only the replacement does.
///
/// The gate is a veto, not a preference: Tiptoe's own patience relaxes over days, this never does.
@MainActor
enum SilentUpdates {
    /// Matches `UpdateCheckService`'s own cadence — this app has never wanted to poll GitHub more
    /// often than once a day, and finding an update sooner would not install it sooner anyway.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    static func start() {
        TiptoeGitHub(owner: "kageroumado", repo: "adrafinil", checkInterval: checkInterval)
            .gate("agents are being kept awake") { await nothingIsBeingKeptAwake() }
            .start()
    }

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
}
