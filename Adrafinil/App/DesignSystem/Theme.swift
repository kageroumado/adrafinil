import SwiftUI

/// Adrafinil's design tokens. The visual identity is the **warm sun**: amber is the "awake / staying
/// up" hue (accent), a cool moon-grey is idle, red signals a safety cutout. Surfaces lean on macOS
/// Liquid Glass; these tokens keep radii, spacing, and color usage consistent across every view.
enum Theme {

    // MARK: - Palette

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

    // MARK: - Geometry

    enum Radius {
        /// Outer cards / panels.
        static let card: CGFloat = 14
        /// Rows and grouped controls inside a card.
        static let inner: CGFloat = 10
        /// Small controls, chips, hover fills.
        static let control: CGFloat = 8
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Fixed width of the menu-bar popover (matches the platform norm).
    static let popoverWidth: CGFloat = 320

    // MARK: - Shapes

    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }
    static var innerShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.inner, style: .continuous) }
    static var controlShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.control, style: .continuous) }
}

extension Font {
    /// Rounded title used for hero lines and headers — friendlier than the default for a utility app.
    static let heroTitle = Font.system(.headline, design: .rounded).weight(.semibold)
    /// Rounded medium-weight body for agent/tool names.
    static let toolName = Font.system(.body, design: .rounded).weight(.medium)
}
