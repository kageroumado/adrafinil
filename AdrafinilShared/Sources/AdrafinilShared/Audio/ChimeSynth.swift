import AVFoundation
import Foundation

/// Pure synthesis of Adrafinil's audio cues, generated at runtime — there are no bundled audio
/// assets. Shared so the two places that need the exact same cue render it from one source: the
/// daemon plays them (via `afplay`, because a LaunchAgent's `AVAudioEngine` output is silent),
/// and the app previews them in Settings (via `NSSound`, fine from a foreground app).
public enum ChimeSynth {
    /// A distinct synthesized cue. Each is a short sine-tone motif whose contour carries the
    /// meaning, so they stay tellable-apart from across a room:
    ///
    /// - `lidClose`: two descending tones (G5 → D5, ~0.4s) — "your Mac is staying awake."
    /// - `sleepWorkComplete`: a descending G-major arpeggio (D6 → B5 → G5, ~0.7s) — "the agents
    ///   finished; goodnight." The happy path, warm and resolved.
    /// - `sleepHoldExpired`: the same note twice (A5, ~0.5s) — neutral, timer-like; the hold ran
    ///   out, the work may not be done.
    /// - `sleepSafetyCutout`: a tritone drop played twice (C5 → F#4, ~0.85s) — deliberately
    ///   unresolved; a safety cutout stopped the work mid-task.
    /// - `sleepUserAction`: a rising fourth (E5 → A5, ~0.45s) — a short "acknowledged" for a
    ///   release the user commanded themselves (e.g. a force release over SSH against a
    ///   closed lid).
    public enum Cue: String, CaseIterable, Sendable {
        case lidClose
        case sleepWorkComplete
        case sleepHoldExpired
        case sleepSafetyCutout
        case sleepUserAction
    }

    /// One note (or rest) of a cue. `frequency == 0` renders silence.
    private struct Segment {
        let frequency: Double
        let duration: Double
    }

    /// Renders `cue` at `volume` (0…1, baked into the samples) to `url` as a `.caf`,
    /// returning `url` on success or `nil` if synthesis or the file write fails.
    @discardableResult
    public static func render(_ cue: Cue, volume: Float, to url: URL) -> URL? {
        let sampleRate = 44_100.0
        guard let buffer = makeBuffer(for: cue, sampleRate: sampleRate, volume: volume) else { return nil }
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    /// Total rendered duration of `cue` in seconds. Exposed so tests can assert the rendered
    /// file matches the motif definition.
    public static func duration(of cue: Cue) -> TimeInterval {
        segments(for: cue).reduce(0) { $0 + $1.duration }
    }

    // Note frequencies (Hz, equal temperament).
    private static let g5 = 783.99, d5 = 587.33
    private static let d6 = 1_174.66, b5 = 987.77, a5 = 880.0
    private static let c5 = 523.25, fSharp4 = 369.99, e5 = 659.26

    private static func segments(for cue: Cue) -> [Segment] {
        switch cue {
        case .lidClose:
            [Segment(frequency: g5, duration: 0.18), Segment(frequency: d5, duration: 0.22)]
        case .sleepWorkComplete:
            [
                Segment(frequency: d6, duration: 0.16),
                Segment(frequency: b5, duration: 0.16),
                Segment(frequency: g5, duration: 0.38),
            ]
        case .sleepHoldExpired:
            [
                Segment(frequency: a5, duration: 0.15),
                Segment(frequency: 0, duration: 0.08),
                Segment(frequency: a5, duration: 0.28),
            ]
        case .sleepSafetyCutout:
            [
                Segment(frequency: c5, duration: 0.14),
                Segment(frequency: fSharp4, duration: 0.20),
                Segment(frequency: 0, duration: 0.10),
                Segment(frequency: c5, duration: 0.14),
                Segment(frequency: fSharp4, duration: 0.26),
            ]
        case .sleepUserAction:
            [
                Segment(frequency: e5, duration: 0.14),
                Segment(frequency: a5, duration: 0.32),
            ]
        }
    }

    /// Peak gain at volume 1. The pre-sleep cues run hotter than the lid-close chime: they play
    /// to a user who may be across the room (issue #8 asked for *louder* than the charger chime),
    /// while the lid-close chime plays under the user's hands.
    private static func gain(for cue: Cue) -> Double {
        cue == .lidClose ? 0.6 : 0.85
    }

    /// Concatenated sine segments with short attack/release envelopes to avoid clicks.
    /// `volume` (0…1) is baked into the samples.
    private static func makeBuffer(for cue: Cue, sampleRate: Double, volume: Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let segs = segments(for: cue)
        // Sum per-segment integer frame counts (rather than truncating the summed duration once)
        // so every allocated frame is written below — no uninitialized tail.
        let counts = segs.map { Int($0.duration * sampleRate) }
        let frames = AVAudioFrameCount(counts.reduce(0, +))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let samples = buffer.floatChannelData![0]
        let g = Double(volume) * gain(for: cue)

        var offset = 0
        for (seg, count) in zip(segs, counts) {
            for i in 0 ..< count {
                guard seg.frequency > 0 else {
                    samples[offset + i] = 0
                    continue
                }
                let t = Double(i) / sampleRate
                let env = envelope(sample: i, count: count, sampleRate: sampleRate)
                samples[offset + i] = Float(sin(2.0 * .pi * seg.frequency * t) * env * g)
            }
            offset += count
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
