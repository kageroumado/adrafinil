import SwiftUI

/// The spiral-eye: the app icon's two-arm spiral galaxy, animated between an **open eye**
/// (the icon's pose — Adrafinil is holding the Mac awake) and a **closed eye** (the spiral
/// wound shut — idle, the Mac sleeps normally).
///
/// ## Geometry
///
/// Arms are logarithmic spirals `r = a·e^(bθ)` whose spiral segment always ends at `θ = 2π`,
/// so the outer tip angle is independent of the pitch `b`: animating the pitch tighter keeps
/// the tips anchored while the inner coil winds around the center like a watch spring.
/// Poses interpolate in *span space* (`span = ln(rOut/rJoin)/b`, the total wrap in radians)
/// so the winding speed is constant across the animation.
///
/// The `almond` parameter reshapes rings structurally (not a final y-squash):
/// `y = sy·r·sign(sin t)·|sin t|^(1+almond)` flattens y near the horizontal extremes, giving
/// lens-shaped rings with pointed canthi — the wound turns nest like eyelid contours, which
/// is what makes the closed pose read as *eyelids* rather than a squashed coil.
nonisolated struct SpiralEyePose: Sendable {
    /// Total log-spiral wrap in radians; the pitch is derived as `b = ln(rOut/rJoin)/span`.
    var span: Double
    /// Radius at the arm tip (1024-space).
    var rOut: Double
    /// Radius where the inner connector hands off to the log spiral.
    var rJoin: Double
    /// Angular span of the inner connector that winds the arm into the exact center.
    var innerSpan: Double
    /// Vertical squish of the whole figure.
    var sy: Double
    /// Phase offset of both arms — the figure's diagonal attitude.
    var tilt: Double
    /// Maximum band width.
    var wMax: Double
    /// Sinusoidal width modulation along the arm (0 = uniform).
    var wobble: Double
    /// Fraction of the arm over which width ramps in from the center.
    var taperIn: Double
    /// Fraction of the arm over which width tapers out to the tip point.
    var taperOut: Double
    /// Pupil radius. Rendered as a punched (transparent) hole; ≤ 0 means no pupil.
    var pupil: Double
    /// Overall scale about the center.
    var scale: Double
    /// Whole-figure rotation (radians).
    var rotation: Double
    /// Canthi pinch exponent (0 = circular rings).
    var almond: Double

    // MARK: - Canonical poses

    /// Menu-bar open pose: ~0.7 turn of fat, wobble-free arms with a big punched pupil.
    /// Tuned at 44 px — the panel geometry mushes at menu-bar size, so the small case gets
    /// its own pose pair rather than shrunk panel art.
    static let menuBarOpen = Self(
        span: 4.4, rOut: 470, rJoin: 165, innerSpan: 1.6, sy: 0.78, tilt: 0.19,
        wMax: 150, wobble: 0, taperIn: 0.30, taperOut: 0.42,
        pupil: 118, scale: 1, rotation: 0, almond: 0,
    )

    /// Menu-bar closed pose: ~1.1 wraps with arms fat enough that the turns merge — the
    /// resting glyph is a clean solid almond with lash tails; the winding shows only in motion.
    /// `wMax` is sized so the two arms' nested wraps *overlap* (half-turn spacing at the
    /// figure's mid-radius is ~126 units) — any thinner and a hairline sliver shows between
    /// them at hero sizes where antialiasing no longer swallows it. The pupil stays slightly
    /// open: the resting idle glyph is a half-closed eye with a small glint of menu bar
    /// showing through, not a solid almond.
    static let menuBarClosed = Self(
        span: 7.0, rOut: 430, rJoin: 70, innerSpan: 2.0, sy: 0.44, tilt: 0.10,
        wMax: 145, wobble: 0, taperIn: 0.07, taperOut: 0.34,
        pupil: 58, scale: 0.96, rotation: -0.08, almond: 1.4,
    )

    /// Large open pose: the shipped app icon's exact arm geometry (generator: bake9.py;
    /// `b = 0.26` ⇒ `span = ln(396/96)/0.26`). For hero artwork ≳ 100 px.
    static let panelOpen = Self(
        span: log(396.0 / 96.0) / 0.26, rOut: 396, rJoin: 96, innerSpan: 3.35, sy: 0.66, tilt: 0.19,
        wMax: 90, wobble: 0.3, taperIn: 0.395, taperOut: 0.37,
        pupil: 95, scale: 1, rotation: 0, almond: 0,
    )

    /// Large closed pose ("spring-squint"): watch-spring wind plus almond ring geometry.
    static let panelClosed = Self(
        span: 13.5, rOut: 382, rJoin: 36, innerSpan: 4.4, sy: 0.42, tilt: 0.10,
        wMax: 48, wobble: 0.08, taperIn: 0.18, taperOut: 0.30,
        pupil: 0, scale: 0.98, rotation: 0, almond: 1.5,
    )

    // MARK: - Interpolation

    /// The pose at `closedness` (0 = open … 1 = closed) between two poses.
    ///
    /// All parameters lerp linearly except the pupil, which leads the close (gone by
    /// closedness ≈ 0.7, before the lids seal) and is deliberately **not clamped below 0**:
    /// a bouncy open animation drives closedness slightly negative at the end of its travel,
    /// popping the pupil wider before it settles — the most visible part of the overshoot
    /// at menu-bar size.
    static func at(_ closedness: Double, from open: Self, to closed: Self) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * closedness }
        return Self(
            span: mix(open.span, closed.span),
            rOut: mix(open.rOut, closed.rOut),
            rJoin: mix(open.rJoin, closed.rJoin),
            innerSpan: mix(open.innerSpan, closed.innerSpan),
            sy: mix(open.sy, closed.sy),
            tilt: mix(open.tilt, closed.tilt),
            wMax: mix(open.wMax, closed.wMax),
            wobble: mix(open.wobble, closed.wobble),
            taperIn: mix(open.taperIn, closed.taperIn),
            taperOut: mix(open.taperOut, closed.taperOut),
            pupil: open.pupil + (closed.pupil - open.pupil) * min(1, closedness * 1.45),
            scale: mix(open.scale, closed.scale),
            rotation: mix(open.rotation, closed.rotation),
            almond: mix(open.almond, closed.almond),
        )
    }
}

// MARK: - Geometry

/// Pure path construction for a ``SpiralEyePose``, in a 1024×1024 logical space centered
/// on (512, 512) with y pointing down. Renderers scale this into their target rect.
nonisolated enum SpiralEyeGeometry {
    /// Logical canvas the paths are expressed in.
    static let space: CGFloat = 1024
    private static let center = CGPoint(x: 512, y: 512)
    /// Sample counts: inner connector + log-spiral segment per arm. Sized for smooth curves
    /// at hero scale while keeping per-frame path construction cheap during animation.
    private static let connectorSamples = 56
    private static let spiralSamples = 280
    private static let smoothingPasses = 3
    /// Pupils smaller than this aren't drawn (mid-animation noise floor).
    static let minimumPupil: Double = 1.5

    /// The two arm outlines (phase 0 and π), as closed filled paths.
    static func armPaths(for pose: SpiralEyePose) -> [CGPath] {
        let phases = [-2 * Double.pi + pose.tilt, .pi - 2 * Double.pi + pose.tilt]
        return phases.enumerated().map { index, phase in
            bandPath(centerline(pose, phase: phase), pose: pose, seed: 0.6 + 2.0 * Double(index))
        }
    }

    /// The center seal: a small lens-shaped disc that grows in once the pupil has closed
    /// (`closedness > 0.72`), covering the sliver the one-sided band offset leaves uncovered
    /// along the innermost centerline wrap. Only needed when the pupil is gone.
    static func sealPath(for pose: SpiralEyePose, closedness: Double) -> CGPath? {
        guard pose.pupil <= minimumPupil, closedness > 0.72 else { return nil }
        let t = (min(closedness, 1) - 0.72) / 0.28
        let r = pose.rJoin * 1.8 * t * pose.scale
        guard r > 0.5 else { return nil }
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: pose.rotation)
            .scaledBy(x: 1, y: pose.sy)
        return CGPath(
            ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r),
            transform: &transform,
        )
    }

    /// The arm's spine: an inner connector that winds from the exact center out to `rJoin`,
    /// then the log spiral out to the tip at `θ = 2π`. Box-smoothed, then rotated/scaled
    /// about the center.
    private static func centerline(_ pose: SpiralEyePose, phase: Double) -> [CGPoint] {
        let b = log(pose.rOut / pose.rJoin) / pose.span
        let th1 = 2 * Double.pi
        let a = pose.rOut / exp(b * th1)
        let th0 = th1 - pose.span

        // Almond ring profile: flatten y near the horizontal extremes → pointed canthi.
        func almondY(_ t: Double) -> Double {
            let s = sin(t)
            return (s < 0 ? -1 : 1) * pow(abs(s), 1 + pose.almond)
        }
        func point(theta: Double, radius: Double) -> CGPoint {
            CGPoint(x: radius * cos(theta + phase), y: pose.sy * radius * almondY(theta + phase))
        }

        var pts: [CGPoint] = []
        pts.reserveCapacity(connectorSamples + spiralSamples)
        for i in 0 ..< connectorSamples {
            let t = Double(i) / Double(connectorSamples - 1)
            pts.append(point(theta: (th0 - pose.innerSpan) + pose.innerSpan * t, radius: pose.rJoin * t))
        }
        for k in 1 ... spiralSamples {
            let theta = th0 + pose.span * Double(k) / Double(spiralSamples)
            pts.append(point(theta: theta, radius: a * exp(b * theta)))
        }

        for _ in 0 ..< smoothingPasses {
            for i in 1 ..< (pts.count - 1) {
                pts[i].x = 0.25 * pts[i - 1].x + 0.5 * pts[i].x + 0.25 * pts[i + 1].x
                pts[i].y = 0.25 * pts[i - 1].y + 0.5 * pts[i].y + 0.25 * pts[i + 1].y
            }
        }
        pts[0] = .zero

        let cosR = cos(pose.rotation), sinR = sin(pose.rotation)
        return pts.map { p in
            CGPoint(
                x: center.x + pose.scale * (p.x * cosR - p.y * sinR),
                y: center.y + pose.scale * (p.x * sinR + p.y * cosR),
            )
        }
    }

    /// Near-one-sided band: the outer edge offsets along the outward normal by the width
    /// profile; the inner edge hugs the centerline but bleeds slightly inward (a fraction of
    /// the local width). In wound poses an arm's centerline nests directly against the other
    /// arm's outer edge — without the bleed a hairline sliver of background shows along that
    /// seam at hero sizes. The bleed makes nested wraps genuinely overlap; the open pose is
    /// unaffected (its pupil is the punched circle, not the band edge).
    private static let innerBleedFraction = 0.18
    private static func bandPath(_ spine: [CGPoint], pose: SpiralEyePose, seed: Double) -> CGPath {
        let n = spine.count
        var inner: [CGPoint] = []
        var outer: [CGPoint] = []
        inner.reserveCapacity(n)
        outer.reserveCapacity(n)
        for i in 0 ..< n {
            let next = spine[min(i + 1, n - 1)], prev = spine[max(i - 1, 0)]
            let dx = next.x - prev.x, dy = next.y - prev.y
            let len = max(hypot(dx, dy), .ulpOfOne)
            var nx = -dy / len, ny = dx / len
            if nx * (spine[i].x - center.x) + ny * (spine[i].y - center.y) < 0 {
                nx = -nx
                ny = -ny
            }
            let w = width(pose, at: Double(i) / Double(n - 1), seed: seed)
            let bleed = w * innerBleedFraction
            inner.append(CGPoint(x: spine[i].x - nx * bleed, y: spine[i].y - ny * bleed))
            outer.append(CGPoint(x: spine[i].x + nx * w, y: spine[i].y + ny * w))
        }

        let path = CGMutablePath()
        path.move(to: inner[0])
        for p in inner.dropFirst() { path.addLine(to: p) }
        for p in outer.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    private static func width(_ pose: SpiralEyePose, at f: Double, seed: Double) -> Double {
        let body = pose.wMax * ((1 - pose.wobble) + pose.wobble * (0.5 + 0.5 * sin(2.6 * .pi * f + seed)))
        let rampIn = pow(min(1, max(0, (f - 0.045) / pose.taperIn)), 0.9)
        let rampOut = pow(min(1, max(0, (1 - f) / pose.taperOut)), 0.9)
        return body * rampIn * rampOut
    }
}

// MARK: - SwiftUI view

/// An animatable spiral-eye. Drive `closedness` between 0 (open) and 1 (closed) inside
/// `withAnimation`/`.animation` and the spiral winds or unwinds — a bouncy spring on open
/// overshoots into a brief pupil pop.
///
/// The fill is a single flat color. When `closedColor` is set, the fill blends toward it
/// as the eye closes — tied to the same `closedness`, so color and wind animate in lockstep.
///
/// The figure fills the frame's width (it is wider than tall) and centers vertically.
struct SpiralEyeView: View, Animatable {
    /// 0 = open eye (icon pose) … 1 = closed (wound shut).
    var closedness: Double
    var color: Color
    /// Fill for the closed pose; `nil` keeps `color` throughout.
    var closedColor: Color?
    /// When set, the pupil is *drawn* as a disc in this color — like the app icon's dark
    /// jewel pin, the visible pupil that makes the eye metaphor read. When `nil`, the pupil
    /// is a punched transparent hole instead — right for the menu bar, where whatever is
    /// behind the template glyph (the bar itself) plays the pupil.
    var pupilColor: Color?
    var variant: Variant = .menuBar

    init(
        closedness: Double, color: Color, closedColor: Color? = nil,
        pupilColor: Color? = nil, variant: Variant = .menuBar,
    ) {
        self.closedness = closedness
        self.color = color
        self.closedColor = closedColor
        self.pupilColor = pupilColor
        self.variant = variant
    }

    /// Which pose pair to interpolate. `.menuBar` is the bold simplified geometry — the
    /// right choice below ~100 px; `.panel` is the app icon's exact arm geometry.
    enum Variant {
        case menuBar
        case panel

        var open: SpiralEyePose { self == .menuBar ? .menuBarOpen : .panelOpen }
        var closed: SpiralEyePose { self == .menuBar ? .menuBarClosed : .panelClosed }
    }

    nonisolated var animatableData: Double {
        get { closedness }
        set { closedness = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let pose = SpiralEyePose.at(closedness, from: variant.open, to: variant.closed)
            let k = size.width / SpiralEyeGeometry.space
            let transform = CGAffineTransform(translationX: 0, y: (size.height - size.width) / 2)
                .scaledBy(x: k, y: k)

            // The figure's pieces (each arm, the seal) overlap, and must be filled
            // separately — a single combined fill lets opposite winding directions cancel
            // to holes where pieces overlap.
            let pieces = (
                SpiralEyeGeometry.armPaths(for: pose).map { Path($0) }
                    + [SpiralEyeGeometry.sealPath(for: pose, closedness: closedness).map(Path.init)]
                    .compactMap(\.self)
            ).map { $0.applying(transform) }

            let pupil: Path? = if pose.pupil > SpiralEyeGeometry.minimumPupil {
                {
                    let r = pose.pupil * pose.scale * k
                    let c = CGPoint(x: 512 * k, y: 512 * k + (size.height - size.width) / 2)
                    return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                }()
            } else {
                nil
            }

            // Render the figure as an opaque mask in a transparency layer, punch the pupil
            // (when it is a hole), then color the mask with a single `.sourceIn` fill —
            // uniform coverage even for translucent colors (`.secondary`) and overlapping
            // pieces.
            context.drawLayer { layer in
                for piece in pieces { layer.fill(piece, with: .color(.black)) }
                if let pupil, pupilColor == nil {
                    layer.blendMode = .destinationOut
                    layer.fill(pupil, with: .color(.black))
                }
                layer.blendMode = .sourceIn
                layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(fillColor))
            }

            // A drawn pupil sits on top of the arms, covering the connector that winds
            // beneath it — exactly how the icon's pin overlays the spiral.
            if let pupil, let pupilColor {
                context.fill(pupil, with: .color(pupilColor))
            }
        }
    }

    private var fillColor: Color {
        guard let closedColor else { return color }
        return color.mix(with: closedColor, by: min(1, max(0, closedness)))
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Spiral eye · states") {
        VStack(spacing: 24) {
            HStack(spacing: 24) {
                SpiralEyeView(closedness: 0, color: .accentColor, pupilColor: .black, variant: .panel)
                    .frame(width: 128, height: 96)
                SpiralEyeView(closedness: 1, color: .accentColor, variant: .panel)
                    .frame(width: 128, height: 96)
                SpiralEyeView(closedness: 0, color: .accentColor, pupilColor: .black, variant: .panel)
                    .frame(width: 30, height: 30)
            }
            // The menu-bar pose pair at debug size — seams and slivers visible here are
            // invisible at 22 pt but show at hero (30 pt) scale.
            HStack(spacing: 24) {
                SpiralEyeView(closedness: 1, color: .secondary)
                    .frame(width: 256, height: 160)
                SpiralEyeView(closedness: 1, color: .black)
                    .frame(width: 256, height: 160)
            }
            HStack(spacing: 24) {
                SpiralEyeView(closedness: 0, color: .primary)
                    .frame(width: 22, height: 22)
                SpiralEyeView(closedness: 1, color: .primary)
                    .frame(width: 22, height: 22)
                SpiralEyeView(closedness: 0, color: .accentColor)
                    .frame(width: 30, height: 30)
                SpiralEyeView(closedness: 1, color: .accentColor, closedColor: .secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(40)
    }

    #Preview("Spiral eye · animated") {
        @Previewable @State var open = true
        VStack(spacing: 24) {
            SpiralEyeView(closedness: open ? 0 : 1, color: .accentColor, closedColor: .secondary, variant: .panel)
                .frame(width: 220, height: 160)
                .animation(open ? .spring(duration: 0.85, bounce: 0.32) : .smooth(duration: 0.8), value: open)
            SpiralEyeView(closedness: open ? 0 : 1, color: .primary)
                .frame(width: 22, height: 22)
                .animation(open ? .spring(duration: 0.85, bounce: 0.32) : .smooth(duration: 0.8), value: open)
            Button(open ? "Close eye" : "Open eye") { open.toggle() }
        }
        .padding(40)
    }
#endif
