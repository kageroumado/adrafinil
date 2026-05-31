import SwiftUI
import AdrafinilShared
import ServiceManagement
import AppKit

struct SettingsView: View {
    /// Binding to the authoritative settings in `AdrafinilApp`.
    /// The General tab writes to this so that `MenuBarExtra(isInserted:)` reacts
    /// immediately when the user toggles "Show in menu bar".
    @Binding var appSettings: AdrafinilSettings

    /// Logic seams — Live in production, mock in previews/gallery.
    var agentHooks: any AgentHooksProviding = LiveAgentHooksProvider()
    var setup: any SetupProviding = LiveSetupProvider()

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: $appSettings)
                .tabItem { Label("General", systemImage: "gear") }
            AgentsSettingsTab(agentHooks: agentHooks)
                .tabItem { Label("Agents", systemImage: "terminal") }
            SafetySettingsTab(settings: $appSettings)
                .tabItem { Label("Safety", systemImage: "thermometer.medium") }
            AboutTab(setup: setup)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Single source of truth: every tab edits this one binding. Persist and propagate
        // centrally so one tab's save can't clobber a field another tab just changed, and
        // re-register the login item only when that specific toggle flips.
        .onChange(of: appSettings) { old, new in
            try? new.save()
            if old.launchAtLogin != new.launchAtLogin {
                Task {
                    if new.launchAtLogin {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? await SMAppService.mainApp.unregister()
                    }
                }
            }
            Task { try? await DaemonClient().reloadSettings() }
        }
    }
}

// MARK: - General tab

struct GeneralSettingsTab: View {
    /// Single shared settings binding owned by `AdrafinilApp`. Editing `showInMenuBar`
    /// updates `MenuBarExtra(isInserted:)` immediately; persistence is handled centrally
    /// by `SettingsView`.
    @Binding var settings: AdrafinilSettings

    private let chimeOptions: [(id: String, label: String)] = [
        ("default", "Adrafinil chime"),
        ("Submarine", "Submarine"),
        ("Ping", "Ping"),
        ("Tink", "Tink"),
        ("Glass", "Glass"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            }

            Section {
                Toggle("Play a sound when you close the lid", isOn: $settings.soundOnLidClose)
                LabeledContent("Volume") {
                    Slider(value: $settings.soundVolume, in: 0...1)
                        .frame(maxWidth: 220)
                }
                .disabled(!settings.soundOnLidClose)
                Picker("Sound", selection: $settings.chimeName) {
                    ForEach(chimeOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .disabled(!settings.soundOnLidClose)

                Toggle("Lock the screen when you close the lid", isOn: $settings.lockOnLidClose)
            } header: {
                Text("When you close the lid")
            } footer: {
                Text("These apply when an agent is still working as you close the lid — a sound to confirm your Mac is staying awake, and a locked screen to keep it private.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents tab

struct AgentsSettingsTab: View {
    let agentHooks: any AgentHooksProviding

    @State private var agentRows: [AgentRowModel] = []

    var body: some View {
        Form {
            Section {
                if agentRows.isEmpty {
                    Text("No supported agents detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($agentRows) { $row in
                        AgentInstallRow(model: $row, agentHooks: agentHooks) { refreshRows() }
                    }
                }
            } header: {
                Text("Your agents")
            } footer: {
                Text("Turn an agent on to let Adrafinil know when it starts and stops working. Turn it off to disconnect it.")
            }

            Section {
                Button("Re-run setup…") {
                    (NSApp.delegate as? AppDelegate)?.presentInstaller()
                }
            } footer: {
                Text("Walk through the setup again to reconnect agents or repair the installation.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshRows() }
    }

    private func refreshRows() {
        agentRows = agentHooks.detectedAgents().map { kind in
            AgentRowModel(kind: kind, installState: agentHooks.installState(for: kind))
        }
    }
}

/// View-model for a single agent row in the Agents tab.
struct AgentRowModel: Identifiable {
    let kind: AgentKind
    var installState: HookInstallState
    var id: AgentKind { kind }
}

private struct AgentInstallRow: View {
    @Binding var model: AgentRowModel
    let agentHooks: any AgentHooksProviding
    let onChange: () -> Void

    private var isInstalled: Bool { model.installState == .installed }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(model.kind.displayName).font(.toolName)

            Spacer(minLength: Theme.Space.md)

            stateChip

            Button { agentHooks.revealConfig(for: model.kind) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal config in Finder")

            Toggle("", isOn: Binding(
                get: { isInstalled },
                set: { newValue in
                    if newValue {
                        try? agentHooks.install(for: model.kind)
                    } else {
                        try? agentHooks.uninstall(for: model.kind)
                    }
                    onChange()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        switch model.installState {
        case .installed:
            StateChip(text: "Installed", systemImage: "checkmark.circle.fill", tint: Theme.ok)
        case .notInstalled:
            StateChip(text: "Not installed", systemImage: "circle", tint: .secondary)
        case .modifiedExternally:
            StateChip(text: "Modified", systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
        }
    }
}

// MARK: - Safety tab

struct SafetySettingsTab: View {
    @Binding var settings: AdrafinilSettings

    var body: some View {
        Form {
            Section("Thermal cutout") {
                Toggle("Force sleep when CPU temperature is too high",
                       isOn: $settings.thermalCutoutEnabled)
                LabeledContent("Threshold") {
                    HStack(spacing: Theme.Space.sm) {
                        Slider(value: $settings.thermalThresholdCelsius, in: 70...95, step: 1)
                            .frame(maxWidth: 180)
                        Text("\(Int(settings.thermalThresholdCelsius))°C")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.thermalCutoutEnabled)
            }

            Section("Low-battery cutout") {
                Toggle("Force sleep when battery runs low (on battery, lid closed)",
                       isOn: $settings.lowBatteryCutoutEnabled)
                LabeledContent("Threshold") {
                    HStack(spacing: Theme.Space.sm) {
                        Slider(value: Binding(
                            get: { Double(settings.lowBatteryThresholdPercent) },
                            set: { settings.lowBatteryThresholdPercent = Int($0) }
                        ), in: 5...50, step: 1)
                        .frame(maxWidth: 180)
                        Text("\(settings.lowBatteryThresholdPercent)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.lowBatteryCutoutEnabled)
            }

            Section {
                Toggle("Stop waiting on agents that go quiet",
                       isOn: $settings.idleReleaseEnabled)
                Stepper(value: $settings.idleReleaseMinutes, in: 1...60) {
                    LabeledContent("Consider quiet after", value: "\(settings.idleReleaseMinutes) min")
                }
                .disabled(!settings.idleReleaseEnabled)
            } header: {
                Text("Idle agents")
            } footer: {
                Text("If an agent does nothing for a while, Adrafinil stops keeping your Mac awake for it — so a stuck or crashed agent can't hold it up forever.")
            }

            Section {
                Toggle("Notice agents even if setup is incomplete",
                       isOn: $settings.processSniffingEnabled)
                Toggle("Start as soon as a known agent launches",
                       isOn: $settings.autoAcquireForKnownAgents)
                    .disabled(!settings.processSniffingEnabled)
            } header: {
                Text("Finding agents")
            } footer: {
                Text("A backup to the per-agent setup: Adrafinil also watches for known agent apps running, in case one starts without notifying it.")
            }

            Section {
                Toggle("Let agents keep your Mac awake on their own",
                       isOn: $settings.agentHoldsEnabled)
                Stepper(value: $settings.manualHoldMaxHours, in: 1...12, step: 1) {
                    LabeledContent("Longest a hold can last",
                                   value: "\(Int(settings.manualHoldMaxHours)) \(Int(settings.manualHoldMaxHours) == 1 ? "hour" : "hours")")
                }
                .disabled(!settings.agentHoldsEnabled)
            } header: {
                Text("Agent holds")
            } footer: {
                Text("An agent can ask Adrafinil to keep your Mac awake for a background task it started — like a long build or deploy — even after it finishes replying. Every hold has a time limit and shows up in the menu, where you can end it yourself.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About tab

struct AboutTab: View {
    let setup: any SetupProviding
    @State private var showUninstallConfirm = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()

            Image(systemName: "sun.max.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.awake)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: Theme.Space.xs) {
                Text("Adrafinil").font(.system(.title, design: .rounded).weight(.semibold))
                Text("Version \(appVersion)").font(.callout).foregroundStyle(.secondary)
            }

            Text("Keep your Mac awake only while AI agents are working.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Link("github.com/kageroumado/adrafinil",
                 destination: URL(string: "https://github.com/kageroumado/adrafinil")!)
                .font(.callout)

            Spacer()

            VStack(spacing: Theme.Space.sm) {
                Button("Uninstall and quit…", role: .destructive) { showUninstallConfirm = true }
                    .tint(Theme.cutout)

                Text("MIT License · © 2026 kageroumado")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer().frame(height: Theme.Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Uninstall Adrafinil?", isPresented: $showUninstallConfirm) {
            Button("Uninstall and Quit", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects Adrafinil from all your agents, turns off its background services, and removes the adrafinil command. This can't be undone.")
        }
    }

    private func performUninstall() {
        Task {
            await setup.uninstallEverything()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Settings · General") {
    @Previewable @State var settings = AdrafinilSettings()
    SettingsView(appSettings: $settings,
                 agentHooks: PreviewAgentHooksProvider(),
                 setup: PreviewSetupProvider())
        .frame(width: 520, height: 560)
}
#Preview("Settings · Agents") {
    AgentsSettingsTab(agentHooks: PreviewAgentHooksProvider())
        .frame(width: 520, height: 560)
}
#Preview("Settings · Safety") {
    @Previewable @State var settings = AdrafinilSettings()
    SafetySettingsTab(settings: $settings)
        .frame(width: 520, height: 560)
}
#Preview("Settings · About") {
    AboutTab(setup: PreviewSetupProvider())
        .frame(width: 520, height: 560)
}
#endif
