import AVFoundation
import Foundation

/// Pure synthesis of Adrafinil's default lid-close cue: a short (~0.4s) two-tone *descending* chime
/// (G5 → D5) generated at runtime with short attack/release envelopes — there is no bundled audio
/// asset. Shared so the two places that need the exact same cue render it from one source: the
/// daemon plays it on lid-close (via `afplay`, because a LaunchAgent's `AVAudioEngine` output is
/// silent), and the app previews it in Settings (via `NSSound`, fine from a foreground app).
public enum ChimeSynth {
    /// Renders the two-tone cue at `volume` (0…1, baked into the samples) to `url` as a `.caf`,
    /// returning `url` on success or `nil` if synthesis or the file write fails.
    @discardableResult
    public static func renderTwoTone(volume: Float, to url: URL) -> URL? {
        let sampleRate = 44_100.0
        guard let buffer = makeTwoToneBuffer(sampleRate: sampleRate, volume: volume) else { return nil }
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    /// Two descending tones (G5 → D5) with short attack/release envelopes to avoid clicks.
    /// `volume` (0…1) is baked into the samples.
    private static func makeTwoToneBuffer(sampleRate: Double, volume: Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
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

    private static func envelope(sample i: Int, count: Int, sampleRate: Double) -> Double {
        let attack = max(1, Int(0.008 * sampleRate))
        let release = max(1, Int(0.04 * sampleRate))
        if i < attack { return Double(i) / Double(attack) }
        if i > count - release { return Double(count - i) / Double(release) }
        return 1.0
    }
}
