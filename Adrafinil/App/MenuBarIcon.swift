import AdrafinilShared
import AppKit
import SwiftUI

/// Menu-bar icon with three states:
///
/// - **Idle** — grayscale outlined moon (template; adapts to the menu-bar appearance).
/// - **Active** — amber filled sun. No count badge: the badge widened the status item
///   (shifting the popover's anchor), and the live count already lives in the popover.
/// - **Cutout** — a red warning icon shown for 30 s after a thermal (exclamation triangle)
///   or low-battery (battery) cutout event, then auto-reverts to idle. The revert is driven
///   by a `Task` that sleeps until the 30-second boundary so the icon updates without
///   waiting for the next 2-second status poll.
///
/// ## Why a pre-rendered `NSImage` instead of a SwiftUI `Image`
///
/// `MenuBarExtra` does **not** rasterize the label view. It resolves the label down to its
/// single `Image` and converts that image's `GraphicsImage` to an `NSImage`
/// (`GraphicsImage.makePlatformImage`), which it sets as the status button's `image`
/// (`MenuBarExtraController.updateButton`). Every other view modifier — `.frame`,
/// `.background`, padding — is discarded along the way; only the resolved `Image` survives.
/// (Verified by disassembling SwiftUI; see `~/Developer/ReverseEngineering`.)
///
/// The consequence: the status item's width tracks the resolved image's width. A bare
/// `Image(systemName:)` resolves to an `NSImage` sized to *that glyph's* bounds, so the
/// width changed between the sun (~18 pt) and the moon (~16 pt), nudging the popover anchor
/// a few pixels on every state change. No SwiftUI-side `.frame`/`.background` could fix it,
/// because those modifiers never reach the status button.
///
/// The fix is to control the `NSImage` directly: each glyph is drawn, scaled-to-fit and
/// centered, into a **constant-size canvas**. `makePlatformImage` preserves an
/// `Image(nsImage:)`'s declared size, so the status item is exactly ``canvasSize`` wide in
/// every state and the popover always anchors to the same point.
struct MenuBarIcon: View {
    let status: AppStatusModel

    /// Bumped by the revert task to force a re-render after the 30-second window.
    @State private var revertTick: UInt = 0

    var body: some View {
        Image(nsImage: Self.image(for: currentState))
            .task(id: cutoutTaskID) {
                await scheduleRevert()
            }
    }

    // MARK: - State machine

    private enum IconState: CaseIterable, Equatable {
        case idle
        case active
        case thermalCutout
        case lowBatteryCutout
    }

    /// Reads `revertTick` so that bumping it in `scheduleRevert` triggers a body re-evaluation.
    private var currentState: IconState {
        _ = revertTick
        guard let s = status.status else { return .idle }

        if let at = s.lastEventAt, Date().timeIntervalSince(at) < 30 {
            if s.lastEvent == .thermalCutout { return .thermalCutout }
            if s.lastEvent == .lowBatteryCutout { return .lowBatteryCutout }
        }

        if s.isBlocking {
            return .active
        }

        return .idle
    }

    // MARK: - Rendering

    /// The SF Symbol and tint for each state. A `nil` tint means "template" — drawn as a mask
    /// and tinted by AppKit to match the menu-bar appearance (the native look for an idle item).
    private static func spec(for state: IconState) -> (symbol: String, tint: NSColor?) {
        switch state {
        case .idle: ("moon", nil)
        case .active: ("sun.max.fill", NSColor(Theme.awake))
        case .thermalCutout: ("exclamationmark.triangle.fill", .systemRed)
        case .lowBatteryCutout: ("battery.25percent", .systemRed)
        }
    }

    private static let pointSize: CGFloat = 15
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)

    /// Fixed status-item footprint. Sized to the steady-state glyphs (moon/sun); the transient
    /// cutout glyphs scale to fit inside it. Constant across every state, so the popover anchor
    /// never moves.
    private static let canvasSize: NSSize = {
        var maxWidth: CGFloat = 0
        var maxHeight: CGFloat = 0
        for name in ["moon", "sun.max.fill"] {
            guard let size = configuredSymbol(name)?.size else { continue }
            maxWidth = max(maxWidth, size.width)
            maxHeight = max(maxHeight, size.height)
        }
        return NSSize(width: ceil(maxWidth) + 2, height: ceil(maxHeight))
    }()

    /// Rendered images are immutable and depend only on the state, so cache them. A cached
    /// template image still adapts to light/dark — AppKit re-tints it on every draw.
    private static var cache: [IconState: NSImage] = [:]

    private static func image(for state: IconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let rendered = render(state)
        cache[state] = rendered
        return rendered
    }

    private static func configuredSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
    }

    private static func render(_ state: IconState) -> NSImage {
        let (symbolName, tint) = spec(for: state)
        guard let symbol = configuredSymbol(symbolName) else {
            return NSImage(size: canvasSize)
        }
        symbol.isTemplate = true

        let canvas = NSImage(size: canvasSize, flipped: false) { rect in
            let fitted = aspectFit(symbol.size, in: rect.size)
            let drawRect = NSRect(
                x: ((rect.width - fitted.width) / 2).rounded(),
                y: ((rect.height - fitted.height) / 2).rounded(),
                width: fitted.width,
                height: fitted.height,
            )
            symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            if let tint {
                tint.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        // A nil tint keeps the icon template-tinted by the menu bar; a concrete tint bakes
        // the color in, so the image must opt out of template handling.
        canvas.isTemplate = tint == nil
        return canvas
    }

    /// The largest size of `aspect` that fits within `bounds` without upscaling.
    private static func aspectFit(_ aspect: NSSize, in bounds: NSSize) -> NSSize {
        guard aspect.width > 0, aspect.height > 0 else { return .zero }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height, 1)
        return NSSize(width: aspect.width * scale, height: aspect.height * scale)
    }

    // MARK: - Revert task

    /// True for the cutout events that get the transient red icon.
    private static func isCutout(_ event: DaemonEvent?) -> Bool {
        event == .thermalCutout || event == .lowBatteryCutout
    }

    /// A stable identity for the `.task(id:)` modifier; changes only when a fresh
    /// cutout event arrives (new `lastEventAt` timestamp).
    private var cutoutTaskID: Date {
        guard Self.isCutout(status.status?.lastEvent),
              let at = status.status?.lastEventAt else { return .distantPast }
        return at
    }

    /// Sleeps until the 30-second cutout window expires, then bumps `revertTick` to force a
    /// re-render. Cancelled automatically if a new `cutoutTaskID` value arrives (via the
    /// `.task(id:)` identity mechanism).
    @MainActor
    private func scheduleRevert() async {
        guard Self.isCutout(status.status?.lastEvent),
              let at = status.status?.lastEventAt else { return }
        let remaining = max(0, 30.05 - Date().timeIntervalSince(at))
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
        revertTick &+= 1
    }
}
