import AdrafinilShared
import AppKit
import SwiftUI

/// Menu-bar icon with three states:
///
/// - **Idle** — the spiral-eye wound shut (template; adapts to the menu-bar appearance).
/// - **Active** — the spiral-eye open: the app icon's spiral pose. Also template — the
///   open/closed eye itself is the state signal, matching the otherwise-monochrome menu bar.
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
/// That also rules out a `Canvas` or animated transitions in the label — the eye is two
/// pre-built frames (open / closed) that swap directly with the state.
///
/// The consequence: the status item's width tracks the resolved image's width, so every state
/// draws into a **constant-size canvas** (``canvasSize``) — the status item stays exactly that
/// wide and the popover always anchors to the same point.
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

    private enum IconState: Equatable {
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

    /// Fixed status-item footprint. The eye renders full-bleed horizontally (it is wider than
    /// tall); the transient cutout glyphs scale to fit inside the same box. Constant across
    /// every state, so the popover anchor never moves.
    private static let canvasSize = NSSize(width: 18, height: 18)

    private static func image(for state: IconState) -> NSImage {
        switch state {
        case .idle:
            eyeImage(open: false)
        case .active:
            eyeImage(open: true)
        case .thermalCutout, .lowBatteryCutout:
            cutoutImage(for: state)
        }
    }

    // MARK: Eye frames

    /// The two eye frames, rendered once and cached. A cached template image still adapts
    /// to light/dark — AppKit re-tints it on every draw.
    private static var eyeCache: [Bool: NSImage] = [:]

    private static func eyeImage(open: Bool) -> NSImage {
        if let cached = eyeCache[open] { return cached }

        let closedness: Double = open ? 0 : 1
        let image = NSImage(size: canvasSize, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let pose: SpiralEyePose = open ? .menuBarOpen : .menuBarClosed
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
            return true
        }
        image.isTemplate = true
        eyeCache[open] = image
        return image
    }

    // MARK: Cutout glyphs

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    private static var cutoutCache: [IconState: NSImage] = [:]

    private static func cutoutImage(for state: IconState) -> NSImage {
        if let cached = cutoutCache[state] { return cached }

        let symbolName = state == .thermalCutout ? "exclamationmark.triangle.fill" : "battery.25percent"
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        else {
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
            NSColor.systemRed.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // The red is baked in, so the image must opt out of template handling.
        canvas.isTemplate = false
        cutoutCache[state] = canvas
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
