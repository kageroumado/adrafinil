import SwiftUI
import AdrafinilShared

/// The window-style popover attached to the menu-bar status item (SPEC §7.1).
struct MenuPopover: View {
    let status: AppStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let s = status.status {
                if s.assertions.isEmpty {
                    Text("No agents active — sleep behavior normal.")
                        .foregroundStyle(.secondary)
                } else {
                    activeSummaryLine(count: s.assertions.count)

                    ForEach(s.assertions) { a in
                        AssertionRow(assertion: a)
                    }
                }

                Divider()

                footer(status: s)
            } else if let err = status.lastError {
                Text("Daemon: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }

            Divider()

            HStack {
                Button("Force sleep now") {
                    Task { await status.forceReleaseAll() }
                }
                .disabled((status.status?.assertions.isEmpty ?? true))

                Spacer()

                Button("Setup…") { (NSApp.delegate as? AppDelegate)?.presentInstaller() }
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Adrafinil").font(.headline)
            Spacer()
            if let s = status.status {
                Text(s.isBlocking ? "blocking sleep" : "idle")
                    .font(.caption)
                    .foregroundStyle(s.isBlocking ? .orange : .secondary)
            }
        }
    }

    private func activeSummaryLine(count: Int) -> some View {
        Text("\(count) \(count == 1 ? "agent" : "agents") active — staying awake")
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.orange)
    }

    private func footer(status s: DaemonStatus) -> some View {
        HStack(spacing: 0) {
            Label(s.lidClosed ? "Lid: closed" : "Lid: open",
                  systemImage: s.lidClosed ? "laptopcomputer.slash" : "laptopcomputer")

            if let temp = s.cpuTemperatureCelsius {
                Text(" · CPU temp: \(Int(temp))°C")
            }

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - AssertionRow

struct AssertionRow: View {
    let assertion: Assertion

    var body: some View {
        HStack {
            Text(assertion.tool)
                .font(.system(.body, design: .rounded).weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(assertion.age.compactDurationString)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = assertion.reason {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
