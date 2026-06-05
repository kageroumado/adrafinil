import AdrafinilShared
import AppKit
import Foundation

/// Plays a one-shot sound preview for the General settings tab, mirroring the daemon's lid-close cue:
/// the default `"Adrafinil chime"` is rendered by the shared `ChimeSynth`; any other name is a macOS
/// system sound under `/System/Library/Sounds`.
///
/// Unlike the daemon — a LaunchAgent whose `AVAudioEngine` output is silent, so it shells out to
/// `afplay` — the app is a foreground (`.regular`) app whenever Settings is open, so `NSSound` routes
/// to hardware normally and needs no external process.
@MainActor
final class ChimePreviewPlayer {
    static let shared = ChimePreviewPlayer()

    /// Held so a still-playing preview is replaced (not overlapped) when the user picks again.
    private var sound: NSSound?

    private init() {}

    /// Plays `chimeName` at `volume` (0…1). Best-effort: silently does nothing if the sound can't be
    /// found or rendered.
    func preview(volume: Float, chimeName: String) {
        sound?.stop()
        let v = max(0, min(1, volume))

        if chimeName != "default" {
            let path = "/System/Library/Sounds/\(chimeName).aiff"
            guard FileManager.default.fileExists(atPath: path) else { return }
            play(URL(fileURLWithPath: path), volume: v)
            return
        }

        // Default cue: render with the volume baked into the samples (matching the daemon), so play
        // the rendered file at unity gain.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adrafinil-chime-preview.caf")
        guard let rendered = ChimeSynth.renderTwoTone(volume: v, to: url) else { return }
        play(rendered, volume: 1)
    }

    private func play(_ url: URL, volume: Float) {
        guard let s = NSSound(contentsOf: url, byReference: true) else { return }
        s.volume = volume
        sound = s
        s.play()
    }
}
