import Foundation
import AppKit
import AVFoundation
import CoreAudio

/// Plays the lid-close confirmation chime (SPEC §6.4 / G5).
///
/// The default chime is synthesized at runtime — a short (~0.4s) two-tone *descending*
/// cue — so there is no audio asset to bundle or license. The user may instead pick a
/// named macOS system sound. The cue is skipped entirely when system output is muted
/// (the lid-open summary covers that case), and respects the configured volume.
@MainActor
final class ChimePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineConfigured = false
    private var systemSound: NSSound?

    /// - Parameters:
    ///   - volume: 0…1 chime level.
    ///   - chimeName: `"default"` for the synthesized two-tone cue, or a macOS system sound name.
    func playLidCloseChime(volume: Float, chimeName: String) {
        guard !systemMuted() else { return }
        let v = max(0, min(1, volume))
        if chimeName != "default", let named = NSSound(named: chimeName) {
            named.volume = v
            named.play()
            systemSound = named
        } else {
            playSynthesizedChime(volume: v)
        }
    }

    // MARK: - Synthesis

    private func playSynthesizedChime(volume: Float) {
        configureEngine()
        guard let buffer = makeTwoToneBuffer(sampleRate: 44_100) else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        engine.mainMixerNode.outputVolume = volume
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func configureEngine() {
        guard !engineConfigured else { return }
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engineConfigured = true
    }

    /// Two descending tones (G5 → D5) with short attack/release envelopes to avoid clicks.
    private func makeTwoToneBuffer(sampleRate: Double) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let seg1 = 0.18, seg2 = 0.22
        let frames = AVAudioFrameCount((seg1 + seg2) * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let samples = buffer.floatChannelData![0]
        let n = Int(frames)
        let n1 = Int(seg1 * sampleRate)
        let f1 = 783.99, f2 = 587.33  // G5, D5

        for i in 0..<n {
            let inFirst = i < n1
            let freq = inFirst ? f1 : f2
            let localStart = inFirst ? 0 : n1
            let localLen = inFirst ? n1 : (n - n1)
            let local = i - localStart
            let localT = Double(local) / sampleRate
            let env = envelope(sample: local, count: localLen, sampleRate: sampleRate)
            samples[i] = Float(sin(2.0 * .pi * freq * localT) * env * 0.6)
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
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return false
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return false }
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muted) == noErr else { return false }
        return muted != 0
    }
}
