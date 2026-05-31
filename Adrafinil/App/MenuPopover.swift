import SwiftUI
import AdrafinilShared

/// The window-style popover attached to the menu-bar status item.
struct MenuPopover: View {
    let status: AppStatusModel

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header

                if let s = status.status {
                    statusCard(s)

                    if !s.assertions.isEmpty {
                        agentList(s.assertions)
                    }

                    metaFooter(s)
                    actions(s)
                } else if let err = status.lastError {
                    errorCard(err)
                    actions(nil)
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 64)
                }
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

    // MARK: - Meta footer

    private func metaFooter(_ s: DaemonStatus) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Label(s.lidClosed ? "Lid closed" : "Lid open",
                  systemImage: s.lidClosed ? "laptopcomputer.slash" : "laptopcomputer")
            if let temp = s.cpuTemperatureCelsius {
                Text("·").foregroundStyle(.tertiary)
                Label("\(Int(temp))°C", systemImage: "thermometer.medium")
                    .foregroundStyle(temp >= 80 ? Theme.cutout : .secondary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.xs)
    }

    // MARK: - Actions

    private func actions(_ s: DaemonStatus?) -> some View {
        let active = !(s?.assertions.isEmpty ?? true)
        return GlassEffectContainer(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await status.forceReleaseAll() }
                } label: {
                    Label("Force sleep", systemImage: "zzz").frame(maxWidth: .infinity)
                }
                .disabled(!active)
                .tint(Theme.awake)

                Button { (NSApp.delegate as? AppDelegate)?.presentInstaller() } label: {
                    Image(systemName: "checklist")
                }
                .help("Re-run setup")

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

    // MARK: - Derived state

    private enum HeroState { case awake, idle, cutout }

    private var state: HeroState {
        guard let s = status.status else { return .idle }
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
        HStack(spacing: Theme.Space.sm) {
            StatusDot(color: Theme.awake, diameter: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(displayTool).font(.toolName)
                    Spacer()
                    Text(assertion.age.compactDurationString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let reason = assertion.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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
#Preview("Popover · daemon error") {
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable()))
}
#Preview("Popover · many agents (dark)") {
    MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
        .preferredColorScheme(.dark)
}
#endif
