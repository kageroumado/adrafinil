import Propofol
import SwiftUI

/// Adrafinil's palette on top of Propofol's shared tokens. The visual identity is the **warm sun**:
/// amber is the "awake / staying up" hue (accent), a cool moon-grey is idle, red signals a safety
/// cutout.
extension Theme {
    /// The amber accent — "awake". Backed by the AccentColor asset (light + dark variants).
    static let awake = Color.accentColor
    /// Foreground for content sitting *on* the saturated amber accent (e.g. a prominent button).
    /// The accent fill stays light in both light and dark mode, so this is a fixed warm near-black
    /// rather than `.primary` (which would flip to white in dark mode and fail contrast on amber).
    static let onAwake = Color(.sRGB, red: 0.16, green: 0.08, blue: 0.0, opacity: 1)
    /// Cool grey for the idle / asleep state.
    static let idle = Color.secondary
    /// Safety cutout (thermal / low-battery force-release).
    static let cutout = Color.red
    /// Non-fatal warning (e.g. a hook modified externally).
    static let warn = Color.orange
    /// Success (installed, finished cleanly).
    static let ok = Color.green

    /// Height cap on the popover's assertion list. Beyond this the list scrolls internally, so a
    /// fleet of holds can never push the bottom bar (lid, temperature, Quit) off-screen. Sized to
    /// keep the whole popover comfortably on a 13" laptop display with every other card visible.
    static let assertionListMaxHeight: CGFloat = 280
}
