import AdrafinilShared
import AppKit
import SwiftUI

/// Menu-bar icon: the spiral eye, optionally with a small corner badge.
///
/// - **Idle** — the spiral-eye wound shut (template; adapts to the menu-bar appearance).
/// - **Active** — the spiral-eye open: the app icon's spiral pose. The open/closed eye itself is the
///   state signal, matching the otherwise-monochrome menu bar.
/// - **Badge** — a small glyph in the top-right corner, over the eye, separated by a cleared ring:
///   a plain dot for "needs attention", or (for the 30 s after a cutout) a `thermometer.high` /
///   battery glyph. **Never colored** — every badge is part of the template mask, so the menu bar
///   tints it the same as the eye. (A cutout used to *replace* the eye with a red full-size battery /
///   warning glyph, which read as "this is your battery/temperature status" rather than Adrafinil's.)
///   The 30 s revert is driven by a `Task` that sleeps to the boundary so the icon updates without
///   waiting for the next status poll.
///
/// ## Why a pre-rendered `NSImage` instead of a SwiftUI `Image`
///
/// `MenuBarExtra` does **not** rasterize the label view. It resolves the label down to its
/// single `Image` and converts that image's `GraphicsImage` to an `NSImage`
/// (`GraphicsImage.makePlatformImage`), which it sets as the status button's `image`
/// (`MenuBarExtraController.updateButton`). Every other view modifier — `.frame`,
/// `.background`, padding — is discarded along the way; only the resolved `Image` survives.
/// That also rules out a `Canvas` or animated transitions in the label — the icon is pre-built
/// frames that swap directly with the state.
///
/// The consequence: the status item's width tracks the resolved image's width, so every state
/// draws into a **constant-size canvas** (``canvasSize``) — the status item stays exactly that
/// wide and the popover always anchors to the same point.
struct MenuBarIcon: View {
    let status: AppStatusModel

    /// Bumped by the revert task to force a re-render after the 30-second window.
    @State private var revertTick: UInt = 0

    var body: some View {
        Image(nsImage: Self.icon(open: baseEyeOpen, badge: currentBadge))
            .task(id: cutoutTaskID) {
                await scheduleRevert()
            }
    }

    // MARK: - State machine

    /// The corner badge drawn over the eye, if any. A cutout (within its 30 s window) takes precedence
    /// over the plain attention dot — it's the more urgent, transient signal.
    private enum Badge: Equatable {
        case none
        case attention
        case thermalCutout
        case lowBatteryCutout
    }

    /// The base eye is open exactly when Adrafinil is holding the Mac awake. A cutout releases every
    /// hold, so during the cutout window the eye reads closed with the cutout glyph badged over it.
    private var baseEyeOpen: Bool {
        status.status?.isBlocking ?? false
    }

    /// Reads `revertTick` so bumping it in `scheduleRevert` re-evaluates the body.
    private var currentBadge: Badge {
        _ = revertTick
        guard let s = status.status else { return .none }
        if let at = s.lastEventAt, Date().timeIntervalSince(at) < 30 {
            if s.lastEvent == .thermalCutout { return .thermalCutout }
            if s.lastEvent == .lowBatteryCutout { return .lowBatteryCutout }
        }
        return status.needsAttention ? .attention : .none
    }

    // MARK: - Rendering

    /// Fixed status-item footprint. The eye renders full-bleed horizontally (it is wider than tall);
    /// a corner badge sits inside the same box. Constant across every state, so the popover anchor
    /// never moves.
    private static let canvasSize = NSSize(width: 18, height: 18)

    private struct IconKey: Hashable {
        let open: Bool
        let badge: Badge
    }

    /// Icon frames cached by `(open, badge)`. Always a **template** image: the menu bar tints status
    /// items to match the wallpaper/appearance, so we never bake a color — a badge is just extra opaque
    /// coverage in the same template mask, separated from the eye by a cleared ring.
    private static var iconCache: [IconKey: NSImage] = [:]

    private static func icon(open: Bool, badge: Badge) -> NSImage {
        let key = IconKey(open: open, badge: badge)
        if let cached = iconCache[key] { return cached }

        let closedness: Double = open ? 0 : 1
        let image = NSImage(size: canvasSize, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let pose: SpiralEyePose = open ? .menuBarOpen : .menuBarClosed
            cg.saveGState()
            let k = rect.width / SpiralEyeGeometry.space
            cg.translateBy(x: 0, y: (rect.height - rect.width) / 2)
            cg.scaleBy(x: k, y: k)

            // Each piece filled separately — a single combined fill lets opposite winding
            // directions cancel to holes where the arms and seal overlap. Opaque black, so
            // overlapping fills are invisible in the template mask.
            cg.setFillColor(NSColor.black.cgColor)
            for arm in SpiralEyeGeometry.armPaths(for: pose) {
                cg.addPath(arm)
                cg.fillPath()
            }
            if let seal = SpiralEyeGeometry.sealPath(for: pose, closedness: closedness) {
                cg.addPath(seal)
                cg.fillPath()
            }
            if pose.pupil > SpiralEyeGeometry.minimumPupil {
                // Negative-space pupil: clear a hole so the menu bar shows through.
                let r = pose.pupil * pose.scale
                cg.setBlendMode(.clear)
                cg.fillEllipse(in: CGRect(x: 512 - r, y: 512 - r, width: 2 * r, height: 2 * r))
                cg.setBlendMode(.normal)
            }
            cg.restoreGState()

            switch badge {
            case .none:
                break
            case .attention:
                drawAttentionDot(in: cg, canvas: rect.size)
            case .thermalCutout:
                drawSymbolBadge(in: cg, canvas: rect.size, symbolName: "thermometer.high")
            case .lowBatteryCutout:
                drawSymbolBadge(in: cg, canvas: rect.size, symbolName: "battery.25percent")
            }
            return true
        }
        image.isTemplate = true
        iconCache[key] = image
        return image
    }

    /// A small dot in the top-right corner, separated from the eye by a cleared ring so it reads as a
    /// distinct dot. No color — part of the template mask, so the menu bar tints it the same as the
    /// eye. Drawn in unscaled canvas (flipped) coordinates, so it's a fixed size regardless of the eye
    /// geometry's 1024-unit space.
    private static func drawAttentionDot(in cg: CGContext, canvas: NSSize) {
        let radius: CGFloat = 3.2
        let center = CGPoint(x: canvas.width - radius - 0.5, y: radius + 0.5) // flipped: small y = top
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: CGRect(
            x: center.x - radius - 1,
            y: center.y - radius - 1,
            width: 2 * (radius + 1),
            height: 2 * (radius + 1),
        ))
        cg.setBlendMode(.normal)
        cg.setFillColor(NSColor.black.cgColor) // opaque template pixel → tints with the eye
        cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private static let badgeSymbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)

    /// Draws an SF Symbol as a top-right corner badge over the eye — the same idea as the attention
    /// dot, just a glyph. Template (uncolored): the symbol's alpha joins the mask and the menu bar
    /// tints it with the eye. A cleared halo behind it keeps it legible where it overlaps an arm.
    private static func drawSymbolBadge(in cg: CGContext, canvas: NSSize, symbolName: String) {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeSymbolConfig)
        else { return }
        symbol.isTemplate = true

        let box: CGFloat = 11
        let boxRect = CGRect(x: canvas.width - box, y: 0, width: box, height: box) // flipped: y=0 is top
        let fitted = aspectFit(symbol.size, in: CGSize(width: box, height: box))
        let drawRect = CGRect(
            x: boxRect.midX - fitted.width / 2,
            y: boxRect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height,
        )
        // Clear a rounded halo around the glyph so it reads as a separate badge over the eye.
        cg.setBlendMode(.clear)
        cg.addPath(CGPath(roundedRect: drawRect.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 2, cornerHeight: 2, transform: nil))
        cg.fillPath()
        cg.setBlendMode(.normal)
        // respectFlipped so the glyph is upright inside the flipped canvas.
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The largest size of `aspect` that fits within `bounds` without upscaling.
    private static func aspectFit(_ aspect: NSSize, in bounds: NSSize) -> NSSize {
        guard aspect.width > 0, aspect.height > 0 else { return .zero }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height, 1)
        return NSSize(width: aspect.width * scale, height: aspect.height * scale)
    }

    // MARK: - Revert task

    /// The cutout events that get the transient 30 s badge.
    private static func isCutout(_ event: DaemonEvent?) -> Bool {
        event == .thermalCutout || event == .lowBatteryCutout
    }

    /// A stable identity for the `.task(id:)` modifier; changes only when a fresh cutout event arrives
    /// (new `lastEventAt` timestamp).
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
