import AdrafinilShared
import SwiftUI

/// The window-style popover attached to the menu-bar status item.
struct MenuPopover: View {
    let status: AppStatusModel
    /// Host hardware, so idle copy avoids mentioning a lid on a desktop Mac. Defaults to the real
    /// device; previews/gallery inject a desktop to exercise the variant.
    var device: DeviceCapabilities = .current

    var body: some View {
        // The model's run-loop poll timer is suspended while the menu-bar popover is open, so a
        // TimelineView drives liveness instead. The per-second hold countdown is now drawn by
        // Text(timerInterval:) (system-managed), so this only needs a coarse tick — enough to
        // refresh the daemon poll, update age labels, and drop a hold from the list shortly after
        // it expires.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
                .task(id: context.date) {
                    await status.refresh()
                }
        }
        .frame(width: Theme.popoverWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let live = liveStatus(now: now)
        let hero = heroState(live, now: now)
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header

                // A failed poll takes precedence: if we can't reach the daemon we don't have
                // trustworthy status, so show the error rather than a stale snapshot.
                if let err = status.lastError {
                    errorCard(err).transition(.popoverSection)
                } else if let live {
                    statusCard(live, state: hero, now: now).transition(.popoverSection)

                    if hero == .awake || hero == .paused {
                        pauseToggleButton(state: hero).transition(.popoverSection)
                    }

                    if !live.assertions.isEmpty {
                        agentList(live.assertions, now: now).transition(.popoverSection)
                    }
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 64)
                }

                bottomBar(status.lastError == nil ? live : nil)
            }
            .padding(Theme.Space.lg)
        }
        // Animate layout (and the window's resize) whenever the set of visible sections changes —
        // hero state, hold count, or a daemon error appearing/disappearing — so clicking "Let it
        // sleep" or an agent finishing glides the panel to its new size instead of snapping.
        .animation(.smooth(duration: 0.3), value: layoutSignature(live, hero))
    }

    /// A compact, order-stable key for the popover's layout: which sections are visible and how
    /// many rows the agent list has. Excludes `now`, so the 5-second tick doesn't trigger animation.
    private func layoutSignature(_ live: DaemonStatus?, _ hero: HeroState) -> String {
        "\(status.lastError != nil)|\(hero)|\(live?.assertions.count ?? -1)"
    }

    /// The daemon snapshot with TTL-expired holds dropped, so a hold disappears the instant its
    /// countdown hits zero rather than lingering until the daemon's next sweep. `isBlocking` is
    /// recomputed from what remains.
    private func liveStatus(now: Date) -> DaemonStatus? {
        guard var s = status.status else { return nil }
        s.assertions = s.assertions.filter { a in
            guard let exp = a.expiresAt else { return true }
            return exp > now
        }
        if s.assertions.isEmpty { s.isBlocking = false }
        return s
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Adrafinil").font(.heroTitle)
            Spacer()
            AttributionLink()
        }
    }

    // MARK: - Status card (hero)

    @ViewBuilder
    private func statusCard(_ s: DaemonStatus, state: HeroState, now _: Date) -> some View {
        switch state {
        case .awake:
            heroCard(
                icon: "sun.max.fill", tint: Theme.awake,
                title: "Keeping your Mac awake",
                subtitle: awakeSubtitle(s), dimmed: false,
            )
        case .cutout:
            heroCard(
                icon: cutoutIcon(s), tint: Theme.cutout,
                title: cutoutTitle(s),
                subtitle: "Your Mac can sleep again", dimmed: false,
            )
        case .idle:
            heroCard(
                icon: "moon.zzz.fill", tint: .secondary,
                title: "Sleeping normally",
                subtitle: device.hasLid
                    ? "No agents active — close the lid and your Mac sleeps"
                    : "No agents active — your Mac sleeps when idle", dimmed: true,
            )
        case .paused:
            heroCard(
                icon: "moon.fill", tint: .secondary,
                title: "Paused",
                subtitle: "Agents can't keep your Mac awake until you resume", dimmed: false,
            )
        }
    }

    /// Describes what's keeping the Mac awake, distinguishing live agents from deliberate holds
    /// (e.g. "2 agents working · 1 hold").
    private func awakeSubtitle(_ s: DaemonStatus) -> String {
        let holds = s.assertions.count(where: { $0.origin == .manual })
        let agents = s.assertions.count - holds
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) \(agents == 1 ? "agent" : "agents") working") }
        if holds > 0 { parts.append("\(holds) \(holds == 1 ? "hold" : "holds")") }
        return parts.isEmpty ? "Your Mac will stay awake" : parts.joined(separator: " · ")
    }

    private func heroCard(icon: String, tint: Color, title: String, subtitle: String, dimmed: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                // Always reserve two lines so a one-line subtitle (e.g. "3 agents working") and a
                // two-line one (e.g. the paused state's "Agents won't keep your Mac awake …") give
                // the card the same height — the pause/resume button below then stays put across
                // states instead of jumping.
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    // Accept the proposed (bounded) width and grow vertically to fit, so a long
                    // subtitle wraps into its reserved second line instead of being measured at its
                    // single-line ideal width and truncated ("…until you…").
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Claim all remaining width so the subtitle has the full card width to wrap into rather
            // than competing with a trailing Spacer for horizontal space.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: dimmed ? nil : tint.opacity(0.18))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 26)).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Adrafinil's helper isn't responding").font(.system(.body, design: .rounded).weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Agent list

    private func agentList(_ assertions: [Assertion], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assertions.enumerated()), id: \.element.id) { index, a in
                if index > 0 { Divider().padding(.leading, Theme.Space.md) }
                AssertionRow(assertion: a, now: now) {
                    Task { await status.releaseAssertion(key: a.key) }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        // A top-level card in the popover, sibling to the hero — so it shares the hero's `card`
        // radius (the `glassCard` default), not the smaller `inner` radius meant for nesting.
        .glassCard()
    }

    // MARK: - Primary action (pause / resume)

    /// Shown directly under the hero so the action reads as part of it. When awake it pauses
    /// Adrafinil ("Let your Mac sleep"); when paused it resumes ("Keep your Mac awake"). Pausing
    /// releases every hold and ignores agents until resumed.
    private func pauseToggleButton(state: HeroState) -> some View {
        let pausing = state == .awake
        return Button {
            Task { await status.setPaused(pausing) }
        } label: {
            Label(
                pausing ? "Let your Mac sleep" : "Keep your Mac awake",
                systemImage: pausing ? "moon.fill" : "sun.max.fill",
            )
            .frame(maxWidth: .infinity)
            .foregroundStyle(Theme.onAwake)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.awake)
        .help(
            pausing
                ? "Pause Adrafinil — your Mac sleeps normally until you resume."
                : "Resume Adrafinil — let agents keep your Mac awake again.",
        )
    }

    // MARK: - Bottom bar (meta + utility actions)

    /// One row: lid/temperature on the left (when known), Settings + Quit on the right.
    private func bottomBar(_ s: DaemonStatus?) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let s { metaLabels(s) }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    SettingsLink { utilityIcon("gearshape") }
                        .help("Settings…")
                    Button { (NSApp.delegate as? AppDelegate)?.confirmQuit() } label: {
                        // `xmark` (quit the app), not `power` — a power glyph in a Mac context
                        // reads as "shut down the Mac", the wrong mental model for closing the app.
                        utilityIcon("xmark")
                    }
                    .help("Quit Adrafinil")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    /// Lid/temperature chips. The popover is only visible while the lid is open or in
    /// clamshell (lid shut + external display), so "open" is implied — only flag clamshell.
    private func metaLabels(_ s: DaemonStatus) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if s.lidClosed {
                Label("Lid closed", systemImage: "laptopcomputer.slash")
            }
            if let temp = s.cpuTemperatureCelsius {
                if s.lidClosed { Text("·").foregroundStyle(.tertiary) }
                Label("\(Int(temp))°C", systemImage: "thermometer.medium")
                    .foregroundStyle(temp >= 80 ? Theme.cutout : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, Theme.Space.xs)
    }

    /// A glyph for the bottom-bar utility buttons (Settings / Quit), pinned to a fixed square so
    /// both `.glass` capsules come out the same size — otherwise each capsule hugs its glyph and
    /// the taller `gearshape` makes its button visibly taller than `xmark`.
    private func utilityIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 16, height: 16)
    }

    // MARK: - Derived state

    private enum HeroState { case awake, idle, cutout, paused }

    private func heroState(_ s: DaemonStatus?, now: Date) -> HeroState {
        guard let s else { return .idle }
        if s.paused { return .paused }
        if let at = s.lastEventAt, now.timeIntervalSince(at) < 30,
           s.lastEvent == .thermalCutout || s.lastEvent == .lowBatteryCutout {
            return .cutout
        }
        return s.isBlocking ? .awake : .idle
    }

    private func cutoutIcon(_ s: DaemonStatus) -> String {
        s.lastEvent == .lowBatteryCutout ? "battery.25percent" : "exclamationmark.triangle.fill"
    }
    private func cutoutTitle(_ s: DaemonStatus) -> String {
        s.lastEvent == .lowBatteryCutout ? "Low-battery cutout" : "Thermal cutout"
    }
}

// MARK: - Transitions

private extension AnyTransition {
    /// How a popover section enters/leaves as the panel resizes around it: a fade with a slight
    /// upward settle, so sections appear to grow out of / collapse into the panel rather than pop.
    static var popoverSection: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

// MARK: - AttributionLink

/// The "made by kageroumado" credit in the popover header. Reads as quiet secondary text but signals
/// it's a link with a trailing external-link arrow, and underlines on hover so the affordance is
/// unmistakable once the pointer lands on it.
private struct AttributionLink: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/kageroumado")!) {
            HStack(spacing: 2) {
                Text("made by kageroumado")
                    .underline(hovering)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - AssertionRow

struct AssertionRow: View {
    let assertion: Assertion
    /// Current time, injected from the popover's TimelineView so the countdown/age tick live while
    /// the popover is open. Defaults to now for non-timeline callers (previews).
    var now: Date = .init()
    /// Non-nil for releasable rows (agent holds). Invoked by the trailing ✕.
    var onRelease: (() -> Void)?

    /// An agent hold (`adrafinil hold` / MCP) — deliberate, reasoned, time-boxed — versus a live
    /// agent session tracked by an editor hook.
    private var isHold: Bool {
        assertion.origin == .manual
    }

    private var displayTool: String {
        AgentKind(rawValue: assertion.tool)?.displayName ?? assertion.tool
    }

    /// A hold shows a live, system-managed countdown (`Text(timerInterval:)` — updates itself every
    /// second down to 0:00 without re-rendering the popover); a live agent shows how long it's been
    /// working, refreshed on the popover's coarse TimelineView tick.
    @ViewBuilder
    private var trailingView: some View {
        if isHold, let exp = assertion.expiresAt {
            // Stable range (acquiredAt…expiresAt) so the timer doesn't reset each tick; it renders
            // the remaining time counting down.
            Text(timerInterval: assertion.acquiredAt ... exp, countsDown: true)
        } else {
            Text(now.timeIntervalSince(assertion.acquiredAt).compactDurationString)
        }
    }

    var body: some View {
        // The leading mark lives on the name line so single-line rows stay vertically centered;
        // a reason, if present, indents beneath it.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.sm) {
                leadingMark
                Text(displayTool).font(.toolName)
                Spacer()
                trailingView
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isHold, let onRelease {
                    Button(action: onRelease) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Release this hold — let the Mac sleep normally")
                }
            }
            if let reason = assertion.reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 14 + Theme.Space.sm)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.md)
    }

    /// A pin marks a deliberate hold; a pulsing dot marks a live agent session.
    @ViewBuilder
    private var leadingMark: some View {
        if isHold {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.awake)
                .frame(width: 14, alignment: .leading)
        } else {
            StatusDot(color: Theme.awake, diameter: 6)
                .frame(width: 14, alignment: .leading)
        }
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Popover · idle") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle))
    }
    #Preview("Popover · idle (desktop)") {
        MenuPopover(
            status: AppStatusModel(previewStatus: Fixtures.idle),
            device: DeviceCapabilities(hasLid: false, hasBattery: false),
        )
    }
    #Preview("Popover · one agent") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent))
    }
    #Preview("Popover · many agents") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
    }
    #Preview("Popover · agent hold") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.withHold))
    }
    #Preview("Popover · thermal cutout") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.thermalCutout))
    }
    #Preview("Popover · paused") {
        var paused = Fixtures.idle
        paused.paused = true
        return MenuPopover(status: AppStatusModel(previewStatus: paused))
    }
    #Preview("Popover · daemon error") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable()))
    }
    #Preview("Popover · many agents (dark)") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
            .preferredColorScheme(.dark)
    }
#endif
