import AVFoundation
import Foundation
import Testing
@testable import AdrafinilShared

@Suite("ChimeSynth")
struct ChimeSynthTests {
    /// Every cue must render a readable, non-silent file of the expected length — a broken
    /// motif table (zero-duration segment, all-rest cue) would otherwise fail silently at
    /// the moment the cue matters most.
    @Test(arguments: ChimeSynth.Cue.allCases)
    func `renders a non-silent file of the expected duration`(cue: ChimeSynth.Cue) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chime-test-\(cue.rawValue)-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ChimeSynth.render(cue, volume: 1, to: url) != nil)

        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        // Frame counts truncate per segment, so allow a small tolerance under the nominal sum.
        #expect(abs(seconds - ChimeSynth.duration(of: cue)) < 0.01)
        #expect(seconds > 0.3, "a cue shorter than ~0.3s won't register across a room")

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try UnsafeBufferPointer(start: #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        #expect(peak > 0.3, "cue \(cue) rendered near-silent (peak \(peak))")
        #expect(peak <= 1.0, "cue \(cue) clips (peak \(peak))")
    }

    /// Volume is baked into the samples (the daemon plays the file at unity gain).
    @Test
    func `volume scales the rendered samples`() throws {
        func peak(volume: Float) throws -> Float {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chime-vol-\(volume)-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(ChimeSynth.render(.sleepWorkComplete, volume: volume, to: url) != nil)
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try UnsafeBufferPointer(start: #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength))
            return samples.reduce(Float(0)) { max($0, abs($1)) }
        }
        let full = try peak(volume: 1)
        let half = try peak(volume: 0.5)
        let zero = try peak(volume: 0)
        #expect(abs(half - full / 2) < 0.01)
        #expect(zero == 0)
    }
}
