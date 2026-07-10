import Foundation
import Testing
@testable import AdrafinilShared

@Suite("SleepCueDecider")
struct SleepCueDeciderTests {
    private let decider = SleepCueDecider()

    private func settings(
        enabled: Bool = true,
        workComplete: String = "default",
        holdExpired: String = "default",
        safetyCutout: String = "default",
        userAction: String = "default",
    ) -> AdrafinilSettings {
        var s = AdrafinilSettings()
        s.sleepSoundEnabled = enabled
        s.sleepChimeWorkComplete = workComplete
        s.sleepChimeHoldExpired = holdExpired
        s.sleepChimeSafetyCutout = safetyCutout
        s.sleepChimeUserAction = userAction
        return s
    }

    // MARK: - Gating

    @Test
    func `lid open is silent for every cause`() {
        for cause in [ReleaseCause.workComplete, .holdExpired, .safetyCutout, .userAction] {
            let d = decider.onSleepResuming(cause: cause, lidClosed: false, settings: settings())
            #expect(d == .silent, "cause \(cause) should be silent with the lid open")
        }
    }

    @Test
    func `master toggle off is silent for every cause`() {
        for cause in [ReleaseCause.workComplete, .holdExpired, .safetyCutout, .userAction] {
            let d = decider.onSleepResuming(cause: cause, lidClosed: true, settings: settings(enabled: false))
            #expect(d == .silent, "cause \(cause) should be silent when disabled")
        }
    }

    /// A user release against a *closed* lid is a remote one (SSH force release) — it gets a
    /// confirmation cue. At-the-machine releases are covered by the lid-open gate above.
    @Test
    func `user action with lid closed gets its confirmation cue`() {
        let d = decider.onSleepResuming(cause: .userAction, lidClosed: true, settings: settings())
        #expect(d == SleepCueDecider.Decision(soundName: "default", cue: .sleepUserAction))
    }

    // MARK: - Cause → sound mapping

    @Test
    func `each cause resolves its own synthesized cue by default`() {
        let s = settings()
        #expect(
            decider.onSleepResuming(cause: .workComplete, lidClosed: true, settings: s)
                == SleepCueDecider.Decision(soundName: "default", cue: .sleepWorkComplete),
        )
        #expect(
            decider.onSleepResuming(cause: .holdExpired, lidClosed: true, settings: s)
                == SleepCueDecider.Decision(soundName: "default", cue: .sleepHoldExpired),
        )
        #expect(
            decider.onSleepResuming(cause: .safetyCutout, lidClosed: true, settings: s)
                == SleepCueDecider.Decision(soundName: "default", cue: .sleepSafetyCutout),
        )
        #expect(
            decider.onSleepResuming(cause: .userAction, lidClosed: true, settings: s)
                == SleepCueDecider.Decision(soundName: "default", cue: .sleepUserAction),
        )
    }

    @Test
    func `per-cause off silences only that cause`() {
        let s = settings(workComplete: "off")
        #expect(decider.onSleepResuming(cause: .workComplete, lidClosed: true, settings: s) == .silent)
        #expect(
            decider.onSleepResuming(cause: .holdExpired, lidClosed: true, settings: s)
                == SleepCueDecider.Decision(soundName: "default", cue: .sleepHoldExpired),
        )
    }

    /// A system-sound pick passes the name through and carries no synth cue.
    @Test
    func `system sound passes through without a synth cue`() {
        let s = settings(safetyCutout: "Submarine")
        let d = decider.onSleepResuming(cause: .safetyCutout, lidClosed: true, settings: s)
        #expect(d == SleepCueDecider.Decision(soundName: "Submarine", cue: nil))
    }

    // MARK: - Idle-batch cause mapping

    @Test
    func `idle batch with any completion-like reason reads as work complete`() {
        #expect(ReleaseCause(idleReleaseReasons: [.cpuIdle]) == .workComplete)
        #expect(ReleaseCause(idleReleaseReasons: [.deadProcess]) == .workComplete)
        // A finished agent is the headline over a co-released expired hold.
        #expect(ReleaseCause(idleReleaseReasons: [.ttlExpired, .cpuIdle]) == .workComplete)
        #expect(ReleaseCause(idleReleaseReasons: [.maxAgeBackstop, .deadProcess]) == .workComplete)
    }

    @Test
    func `idle batch of pure expiries reads as hold expired`() {
        #expect(ReleaseCause(idleReleaseReasons: [.ttlExpired]) == .holdExpired)
        #expect(ReleaseCause(idleReleaseReasons: [.maxAgeBackstop]) == .holdExpired)
        #expect(ReleaseCause(idleReleaseReasons: [.ttlExpired, .maxAgeBackstop]) == .holdExpired)
    }

    /// Degenerate but safe: an empty batch defaults to the happy-path cue.
    @Test
    func `empty idle batch defaults to work complete`() {
        #expect(ReleaseCause(idleReleaseReasons: []) == .workComplete)
    }
}
