import Foundation

/// Why the daemon stopped keeping the Mac awake — the category of the release that took the
/// registry to zero. Recorded by the daemon at each release site and read on the blocking→idle
/// edge to pick the pre-sleep cue.
public enum ReleaseCause: String, Sendable, Equatable {
    /// The happy path: the agent's end hook released, its process exited, or the CPU-idle sweep
    /// decided it was done.
    case workComplete
    /// A hold's TTL ran out (or the max-age backstop fired) — the work may *not* be finished.
    case holdExpired
    /// A thermal or low-battery cutout stopped the work mid-task to protect the machine.
    case safetyCutout
    /// The user did it themselves (force release, pause, quit). With the lid closed — the only
    /// state where any cue plays — that means a *remote* release, typically over SSH.
    case userAction

    /// Collapses an idle-sweep batch to a single cause. An agent finishing (CPU-idle or its
    /// process exiting) is the headline over a co-released expired hold, so any completion-like
    /// reason wins; a batch of pure expiries is `holdExpired`.
    public init(idleReleaseReasons reasons: [IdleReleaseEvaluator.Release.Reason]) {
        let completionLike = reasons.contains { $0 == .cpuIdle || $0 == .deadProcess }
        self = (completionLike || reasons.isEmpty) ? .workComplete : .holdExpired
    }
}

/// Decides whether (and what) to play the instant the last assertion releases — the moment
/// before the daemon clears the sleep block and a closed-lid Mac goes back to sleep.
///
/// Pure and side-effect-free, mirroring `LidActionDecider`, so the gating is exhaustively
/// unit-testable. The gates:
///
/// - **Lid open → silent.** The user is present and can see the menu-bar state; the cue exists
///   for the closed-lid, user-away case (issue #8). This gate also keeps `userAction` sensible:
///   a force release clicked at the machine is silent, while one issued remotely (SSH against a
///   closed lid) gets its confirmation cue.
/// - **Master toggle off → silent.**
/// - Otherwise the cause's configured sound plays: `"default"` is the synthesized cue for that
///   cause, `"off"` silences just that cause, anything else names a macOS system sound.
public struct SleepCueDecider {
    public struct Decision: Equatable, Sendable {
        /// `nil` → stay silent. `"default"` → play `cue`; anything else is a system sound name.
        public let soundName: String?
        /// The synthesized cue to render when `soundName == "default"`, else `nil`.
        public let cue: ChimeSynth.Cue?

        public static let silent = Decision(soundName: nil, cue: nil)

        public init(soundName: String?, cue: ChimeSynth.Cue?) {
            self.soundName = soundName
            self.cue = cue
        }
    }

    public init() {}

    public func onSleepResuming(
        cause: ReleaseCause,
        lidClosed: Bool,
        settings: AdrafinilSettings,
    ) -> Decision {
        guard lidClosed, settings.sleepSoundEnabled else { return .silent }
        let soundName: String
        let cue: ChimeSynth.Cue
        switch cause {
        case .workComplete:
            (soundName, cue) = (settings.sleepChimeWorkComplete, .sleepWorkComplete)
        case .holdExpired:
            (soundName, cue) = (settings.sleepChimeHoldExpired, .sleepHoldExpired)
        case .safetyCutout:
            (soundName, cue) = (settings.sleepChimeSafetyCutout, .sleepSafetyCutout)
        case .userAction:
            (soundName, cue) = (settings.sleepChimeUserAction, .sleepUserAction)
        }
        guard soundName != "off" else { return .silent }
        return Decision(soundName: soundName, cue: soundName == "default" ? cue : nil)
    }
}
