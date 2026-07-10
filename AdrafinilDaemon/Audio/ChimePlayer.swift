import AdrafinilShared
import CoreAudio
import Foundation
import OSLog

/// Plays the daemon's audio cues: the lid-close confirmation chime (fire-and-forget) and the
/// pre-sleep cue (awaited, so the caller can sequence "cue audible → then allow sleep").
///
/// The default cues are synthesized at runtime by the shared `ChimeSynth` — no bundled assets —
/// and played with `afplay`. The user may instead pick a named macOS system sound. Cues are
/// skipped when system output is muted (the lid-open summary covers that case) and respect the
/// configured volume.
///
/// > Playback uses `/usr/bin/afplay`, not `AVAudioEngine`: a LaunchAgent (this daemon) can drive
/// > an engine without error yet produce no audible output — the engine's output node doesn't
/// > route to hardware from a background-agent context. `afplay` is a self-contained player that
/// > routes correctly. Verified on macOS 26.3 (engine: silent; afplay: audible).
@MainActor
final class ChimePlayer {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "Chime")

    /// Held so the fire-and-forget `afplay` isn't torn down early; replaced on each play.
    private var player: Process?

    /// - Parameters:
    ///   - volume: 0…1 chime level.
    ///   - chimeName: `"default"` for the synthesized two-tone cue, or a macOS system sound name.
    func playLidCloseChime(volume: Float, chimeName: String) {
        guard !systemMuted() else { log.notice("lid-close chime skipped — system output muted"); return }
        let v = max(0, min(1, volume))

        if chimeName != "default", let soundPath = systemSoundPath(named: chimeName) {
            log.notice("playing lid-close system sound '\(chimeName, privacy: .public)' at volume \(v, privacy: .public)")
            afplay(path: soundPath, volume: v)
            return
        }

        guard let chimePath = render(.lidClose, volume: v) else {
            log.error("lid-close chime — failed to render two-tone")
            return
        }
        log.notice("playing lid-close two-tone chime at volume \(v, privacy: .public)")
        // Volume is baked into the rendered samples, so play at unity gain.
        afplay(path: chimePath, volume: 1)
    }

    /// Plays the pre-sleep cue and **waits for playback to finish** (bounded by `timeout`), so
    /// the daemon can clear the sleep block only after the cue has been heard — with the lid
    /// closed, that clear is what lets the Mac sleep. A wedged `afplay` can't stall the sleep
    /// gate past the timeout.
    ///
    /// - Parameters:
    ///   - soundName: `"default"` plays the synthesized `cue`; anything else is a macOS system
    ///     sound name. (`"off"`/silence is decided upstream by `SleepCueDecider` — this method
    ///     always tries to play.)
    ///   - cue: the synthesized cue to render when `soundName == "default"`.
    ///   - volume: 0…1 level.
    func playSleepCue(soundName: String, cue: ChimeSynth.Cue?, volume: Float, timeout: TimeInterval = 6) async {
        guard !systemMuted() else {
            log.notice("pre-sleep cue skipped — system output muted")
            return
        }
        let v = max(0, min(1, volume))

        let path: String?
        let playVolume: Float
        if soundName != "default", let soundPath = systemSoundPath(named: soundName) {
            (path, playVolume) = (soundPath, v)
        } else {
            // Volume is baked into the rendered samples, so play at unity gain.
            (path, playVolume) = (render(cue ?? .sleepWorkComplete, volume: v), 1)
        }
        guard let path else {
            log.error("pre-sleep cue — failed to render '\(soundName, privacy: .public)'")
            return
        }
        log.notice("playing pre-sleep cue '\(soundName, privacy: .public)' at volume \(v, privacy: .public)")
        await afplayAndWait(path: path, volume: playVolume, timeout: timeout)
    }

    // MARK: - Playback

    private func afplay(path: String, volume: Float) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["-v", String(volume), path]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run() // fire-and-forget; the ~0.4s clip plays out on its own
            player = task
        } catch {
            log.error("afplay failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Launches `afplay` and suspends until the clip finishes playing (it exits at end-of-file),
    /// bounded by `timeout`. `terminationHandler` and the timeout can race — `OnceResumer` makes
    /// the first outcome win.
    private func afplayAndWait(path: String, volume: Float, timeout: TimeInterval) async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["-v", String(volume), path]
        task.standardOutput = nil
        task.standardError = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResumer<Void> { cont.resume() }
            task.terminationHandler = { _ in once.resume(()) }
            do {
                try task.run()
                player = task
            } catch {
                log.error("afplay failed to launch: \(error.localizedDescription, privacy: .public)")
                once.resume(())
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(()) }
        }
    }

    /// `/System/Library/Sounds/<name>.aiff`, or nil if no such system sound.
    private func systemSoundPath(named name: String) -> String? {
        let path = "/System/Library/Sounds/\(name).aiff"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Synthesis

    /// Renders a shared synthesized cue to a temp file and returns its path (overwritten per
    /// cue on each call). The synthesis itself lives in `ChimeSynth` (AdrafinilShared) so the
    /// Settings preview plays an identical cue.
    private func render(_ cue: ChimeSynth.Cue, volume: Float) -> String? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adrafinil-\(cue.rawValue).caf")
        guard let rendered = ChimeSynth.render(cue, volume: volume, to: url) else {
            log.error("cue render — synthesis/write failed for \(cue.rawValue, privacy: .public)")
            return nil
        }
        return rendered.path
    }

    // MARK: - Mute detection

    /// Whether the default output device is muted. Best-effort; defaults to "not muted".
    private func systemMuted() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return false
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return false }
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muted) == noErr else { return false }
        return muted != 0
    }
}
