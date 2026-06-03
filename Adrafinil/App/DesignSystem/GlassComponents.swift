import SwiftUI

// MARK: - Glass surfaces

extension View {
    /// Wraps the view in a Liquid Glass card with Adrafinil's standard radius. Pass `tint` to give
    /// the glass a warm cast (e.g. amber for the active hero).
    func glassCard(cornerRadius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return glassEffect(glass, in: shape)
    }
}

// MARK: - Status dot

/// A small filled state indicator. `glow` adds a soft halo for the active state.
struct StatusDot: View {
    let color: Color
    var glow: Bool = false
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: glow ? 4 : 0)
    }
}

// MARK: - State chip

/// A compact pill used for install state, detection, and tier badges.
struct StateChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Popover menu item style

/// A full-width, left-aligned button with a subtle hover fill — the popover's primary action row
/// style (adapted from Phosphene's menu-item style). Use inside the popover's footer/menu.
struct PopoverMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ItemBody(configuration: configuration)
    }

    private struct ItemBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.controlShape.fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Theme.controlShape)
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PopoverMenuItemStyle {
    static var popoverItem: PopoverMenuItemStyle {
        PopoverMenuItemStyle()
    }
}
