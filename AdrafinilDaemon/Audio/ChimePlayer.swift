import AdrafinilShared
import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Plays the lid-close confirmation chime.
///
/// The default cue is a short (~0.4s) two-tone *descending* chime (G5 → D5) synthesized at
/// runtime — no bundled asset — and played with `afplay`. The user may instead pick a named
/// macOS system sound. The cue is skipped when system output is muted (the lid-open summary
/// covers that case) and respects the configured volume.
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

        guard let chimePath = renderTwoTone(volume: v) else {
            log.error("lid-close chime — failed to render two-tone")
            return
        }
        log.notice("playing lid-close two-tone chime at volume \(v, privacy: .public)")
        // Volume is baked into the rendered samples, so play at unity gain.
        afplay(path: chimePath, volume: 1)
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

    /// `/System/Library/Sounds/<name>.aiff`, or nil if no such system sound.
    private func systemSoundPath(named name: String) -> String? {
        let path = "/System/Library/Sounds/\(name).aiff"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Synthesis

    /// Renders the two-tone chime to a temp file and returns its path (overwritten each call).
    private func renderTwoTone(volume: Float) -> String? {
        let sampleRate = 44_100.0
        guard let buffer = makeTwoToneBuffer(sampleRate: sampleRate, volume: volume) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adrafinil-chime.caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return url.path
        } catch {
            log.error("renderTwoTone — write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Two descending tones (G5 → D5) with short attack/release envelopes to avoid clicks.
    /// `volume` (0…1) is baked into the samples.
    private func makeTwoToneBuffer(sampleRate: Double, volume: Float) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let seg1 = 0.18, seg2 = 0.22
        let frames = AVAudioFrameCount((seg1 + seg2) * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let samples = buffer.floatChannelData![0]
        let n = Int(frames)
        let n1 = Int(seg1 * sampleRate)
        let f1 = 783.99, f2 = 587.33 // G5, D5
        let gain = Double(volume) * 0.6

        for i in 0 ..< n {
            let inFirst = i < n1
            let freq = inFirst ? f1 : f2
            let localStart = inFirst ? 0 : n1
            let localLen = inFirst ? n1 : (n - n1)
            let local = i - localStart
            let localT = Double(local) / sampleRate
            let env = envelope(sample: local, count: localLen, sampleRate: sampleRate)
            samples[i] = Float(sin(2.0 * .pi * freq * localT) * env * gain)
        }
        return buffer
    }

    private func envelope(sample i: Int, count: Int, sampleRate: Double) -> Double {
        let attack = max(1, Int(0.008 * sampleRate))
        let release = max(1, Int(0.04 * sampleRate))
        if i < attack { return Double(i) / Double(attack) }
        if i > count - release { return Double(count - i) / Double(release) }
        return 1.0
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
