import SwiftUI
import AdrafinilShared

/// The window-style popover attached to the menu-bar status item.
struct MenuPopover: View {
    let status: AppStatusModel

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header

                // A failed poll takes precedence: if we can't reach the daemon we don't have
                // trustworthy status, so show the error rather than a stale snapshot.
                if let err = status.lastError {
                    errorCard(err)
                } else if let s = status.status {
                    statusCard(s)

                    if state == .awake || state == .paused {
                        pauseToggleButton
                    }

                    if !s.assertions.isEmpty {
                        agentList(s.assertions)
                    }
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 64)
                }

                bottomBar(status.lastError == nil ? status.status : nil)
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: Theme.popoverWidth)
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
    private func statusCard(_ s: DaemonStatus) -> some View {
        switch state {
        case .awake:
            heroCard(
                icon: "sun.max.fill", tint: Theme.awake,
                title: "Staying awake",
                subtitle: "\(s.assertions.count) \(s.assertions.count == 1 ? "agent" : "agents") working")
        case .cutout:
            heroCard(
                icon: cutoutIcon(s), tint: Theme.cutout,
                title: cutoutTitle(s),
                subtitle: "Sleep is back to normal")
        case .idle:
            heroCard(
                icon: "moon.zzz.fill", tint: .secondary,
                title: "Sleeping normally",
                subtitle: "No agents active — close the lid and it sleeps")
        case .paused:
            heroCard(
                icon: "pause.circle.fill", tint: .secondary,
                title: "Paused",
                subtitle: "Adrafinil is off — agents won't keep your Mac awake")
        }
    }

    private func heroCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
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
        .glassCard(tint: state == .idle ? nil : tint.opacity(0.18))
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

    private func agentList(_ assertions: [Assertion]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assertions.enumerated()), id: \.element.id) { index, a in
                if index > 0 { Divider().padding(.leading, Theme.Space.md) }
                AssertionRow(assertion: a)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .glassCard(cornerRadius: Theme.Radius.inner)
    }

    // MARK: - Primary action (pause / resume)

    /// Shown directly under the hero so the action reads as part of it. When awake it pauses
    /// Adrafinil ("Let it sleep"); when paused it resumes ("Resume"). Pausing releases every
    /// hold and ignores agents until resumed.
    private var pauseToggleButton: some View {
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

    private var state: HeroState {
        guard let s = status.status else { return .idle }
        if s.paused { return .paused }
        if let at = s.lastEventAt, Date().timeIntervalSince(at) < 30,
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

    private var displayTool: String {
        AgentKind(rawValue: assertion.tool)?.displayName ?? assertion.tool
    }

    var body: some View {
        // Dot lives on the name line so single-line rows (the normal case — hooks don't
        // report a reason) stay vertically centered; a reason, if present, indents beneath.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.sm) {
                StatusDot(color: Theme.awake, diameter: 6)
                Text(displayTool).font(.toolName)
                Spacer()
                Text(assertion.age.compactDurationString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let reason = assertion.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 6 + Theme.Space.sm)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.md)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Popover · idle") {
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle))
}
#Preview("Popover · one agent") {
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent))
}
#Preview("Popover · many agents") {
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
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
