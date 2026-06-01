import SwiftUI
import AdrafinilShared

/// The window-style popover attached to the menu-bar status item.
struct MenuPopover: View {
    let status: AppStatusModel
    /// Host hardware, so idle copy avoids mentioning a lid on a desktop Mac. Defaults to the real
    /// device; previews/gallery inject a desktop to exercise the variant.
    var device: DeviceCapabilities = .current

    var body: some View {
        // Drive the popover from a TimelineView. The model's run-loop poll timer is suspended while
        // the menu-bar popover is open, which froze hold countdowns and left TTL-expired holds on
        // screen. TimelineView re-renders reliably here, so we use it both to tick the countdowns
        // (from `context.date`) and to keep the daemon poll running while the popover is up.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
                .task(id: Int(context.date.timeIntervalSinceReferenceDate) / 2) {
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
                    errorCard(err)
                } else if let live {
                    statusCard(live, state: hero, now: now)

                    if hero == .awake || hero == .paused {
                        pauseToggleButton(state: hero)
                    }

                    if !live.assertions.isEmpty {
                        agentList(live.assertions, now: now)
                    }
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 64)
                }

                bottomBar(status.lastError == nil ? live : nil)
            }
            .padding(Theme.Space.lg)
        }
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
            Link("made by kageroumado", destination: URL(string: "https://github.com/kageroumado")!)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status card (hero)

    @ViewBuilder
    private func statusCard(_ s: DaemonStatus, state: HeroState, now: Date) -> some View {
        switch state {
        case .awake:
            heroCard(
                icon: "sun.max.fill", tint: Theme.awake,
                title: "Staying awake",
                subtitle: awakeSubtitle(s), dimmed: false)
        case .cutout:
            heroCard(
                icon: cutoutIcon(s), tint: Theme.cutout,
                title: cutoutTitle(s),
                subtitle: "Sleep is back to normal", dimmed: false)
        case .idle:
            heroCard(
                icon: "moon.zzz.fill", tint: .secondary,
                title: "Sleeping normally",
                subtitle: device.hasLid
                    ? "No agents active — close the lid and it sleeps"
                    : "No agents active — it sleeps when idle", dimmed: true)
        case .paused:
            heroCard(
                icon: "pause.circle.fill", tint: .secondary,
                title: "Paused",
                subtitle: "Adrafinil is off — agents won't keep your Mac awake", dimmed: false)
        }
    }

    /// Describes what's keeping the Mac awake, distinguishing live agents from deliberate holds
    /// (e.g. "2 agents working · 1 hold").
    private func awakeSubtitle(_ s: DaemonStatus) -> String {
        let holds = s.assertions.filter { $0.origin == .manual }.count
        let agents = s.assertions.count - holds
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) \(agents == 1 ? "agent" : "agents") working") }
        if holds > 0 { parts.append("\(holds) \(holds == 1 ? "hold" : "holds")") }
        return parts.isEmpty ? "Keeping your Mac awake" : parts.joined(separator: " · ")
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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
                Text("Daemon not reachable").font(.system(.body, design: .rounded).weight(.semibold))
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
        .glassCard(cornerRadius: Theme.Radius.inner)
    }

    // MARK: - Primary action (pause / resume)

    /// Shown directly under the hero so the action reads as part of it. When awake it pauses
    /// Adrafinil ("Let it sleep"); when paused it resumes ("Resume"). Pausing releases every
    /// hold and ignores agents until resumed.
    private func pauseToggleButton(state: HeroState) -> some View {
        let pausing = state == .awake
        return Button {
            Task { await status.setPaused(pausing) }
        } label: {
            Label(pausing ? "Let it sleep" : "Resume",
                  systemImage: pausing ? "moon.fill" : "sun.max.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.awake)
        .help(pausing
              ? "Pause Adrafinil — your Mac sleeps normally until you resume."
              : "Resume Adrafinil — let agents keep your Mac awake again.")
    }

    // MARK: - Bottom bar (meta + utility actions)

    /// One row: lid/temperature on the left (when known), Settings + Quit on the right.
    private func bottomBar(_ s: DaemonStatus?) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let s { metaLabels(s) }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings…")
                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power")
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
    @ViewBuilder
    private func metaLabels(_ s: DaemonStatus) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if s.lidClosed {
                Label("Clamshell", systemImage: "laptopcomputer.slash")
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

// MARK: - AssertionRow

struct AssertionRow: View {
    let assertion: Assertion
    /// Current time, injected from the popover's TimelineView so the countdown/age tick live while
    /// the popover is open. Defaults to now for non-timeline callers (previews).
    var now: Date = Date()
    /// Non-nil for releasable rows (agent holds). Invoked by the trailing ✕.
    var onRelease: (() -> Void)? = nil

    /// An agent hold (`adrafinil hold` / MCP) — deliberate, reasoned, time-boxed — versus a live
    /// agent session tracked by an editor hook.
    private var isHold: Bool { assertion.origin == .manual }

    private var displayTool: String {
        AgentKind(rawValue: assertion.tool)?.displayName ?? assertion.tool
    }

    /// A hold shows its countdown; a live agent shows how long it's been working. Both derive from
    /// the injected `now`, so they update on each TimelineView tick.
    private var trailingText: String {
        if isHold, let exp = assertion.expiresAt {
            let remaining = exp.timeIntervalSince(now)
            if remaining > 0 { return remaining.remainingString }
        }
        return now.timeIntervalSince(assertion.acquiredAt).compactDurationString
    }

    var body: some View {
        // The leading mark lives on the name line so single-line rows stay vertically centered;
        // a reason, if present, indents beneath it.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.sm) {
                leadingMark
                Text(displayTool).font(.toolName)
                Spacer()
                Text(trailingText)
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
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle),
                device: DeviceCapabilities(hasLid: false, hasBattery: false))
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
