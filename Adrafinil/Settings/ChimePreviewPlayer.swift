import AdrafinilShared
import AppKit
import Foundation

/// Plays a one-shot sound preview for the General settings tab, mirroring the daemon's cues:
/// a `"default"` sound is rendered by the shared `ChimeSynth` (the lid-close chime or one of the
/// pre-sleep cues, per `cue`); any other name is a macOS system sound under
/// `/System/Library/Sounds`; `"off"` previews as silence.
///
/// Unlike the daemon — a LaunchAgent whose `AVAudioEngine` output is silent, so it shells out to
/// `afplay` — the app is a foreground (`.regular`) app whenever Settings is open, so `NSSound`
/// routes to hardware normally and needs no external process.
@MainActor
final class ChimePreviewPlayer {
    static let shared = ChimePreviewPlayer()

    /// Held so a still-playing preview is replaced (not overlapped) when the user picks again.
    private var sound: NSSound?

    private init() {}

    /// Plays `soundName` at `volume` (0…1), rendering `cue` when the name is `"default"`.
    /// Best-effort: silently does nothing for `"off"` or if the sound can't be found or rendered.
    func preview(volume: Float, soundName: String, cue: ChimeSynth.Cue = .lidClose) {
        sound?.stop()
        guard soundName != "off" else { return }
        let v = max(0, min(1, volume))

        if soundName != "default" {
            let path = "/System/Library/Sounds/\(soundName).aiff"
            guard FileManager.default.fileExists(atPath: path) else { return }
            play(URL(fileURLWithPath: path), volume: v)
            return
        }

        // Default cue: render with the volume baked into the samples (matching the daemon), so play
        // the rendered file at unity gain.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adrafinil-preview-\(cue.rawValue).caf")
        guard let rendered = ChimeSynth.render(cue, volume: v, to: url) else { return }
        play(rendered, volume: 1)
    }

    private func play(_ url: URL, volume: Float) {
        guard let s = NSSound(contentsOf: url, byReference: true) else { return }
        s.volume = volume
        sound = s
        s.play()
    }
}
