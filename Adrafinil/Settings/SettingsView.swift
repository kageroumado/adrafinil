import AdrafinilShared
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    /// Binding to the authoritative settings in `AdrafinilApp`.
    /// The General tab writes to this so that `MenuBarExtra(isInserted:)` reacts
    /// immediately when the user toggles "Show in menu bar".
    @Binding var appSettings: AdrafinilSettings

    /// Logic seams — Live in production, mock in previews/gallery.
    var agentHooks: any AgentHooksProviding = LiveAgentHooksProvider()
    var setup: any SetupProviding = LiveSetupProvider()
    /// Host hardware, so the lid/battery-specific controls hide on a desktop Mac. Defaults to the
    /// real device; previews/gallery inject a desktop to exercise the degraded layout.
    var device: DeviceCapabilities = .current

    /// Debounces the cross-process settings reload so dragging a slider (which fires `onChange`
    /// continuously) triggers one daemon reload after the drag settles, not dozens during it.
    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: $appSettings, setup: setup, device: device)
                .tabItem { Label("General", systemImage: "gear") }
            AgentsSettingsTab(agentHooks: agentHooks)
                .tabItem { Label("Agents", systemImage: "terminal") }
            SafetySettingsTab(settings: $appSettings, device: device)
                .tabItem { Label("Safety", systemImage: "checkmark.shield") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Single source of truth: every tab edits this one binding. Persist and propagate
        // centrally so one tab's save can't clobber a field another tab just changed, and
        // re-register the login item only when that specific toggle flips.
        .onChange(of: appSettings) { old, new in
            // Persist immediately — it's a small local write and must never be lost if the window
            // closes mid-edit.
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
            // Debounce the daemon reload so a slider drag doesn't fire a cross-process reload (and a
            // daemon-side disk re-read) on every intermediate value.
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                try? await DaemonClient.shared.reloadSettings()
            }
        }
    }
}

// MARK: - General tab

struct GeneralSettingsTab: View {
    /// Single shared settings binding owned by `AdrafinilApp`. Editing `showInMenuBar`
    /// updates `MenuBarExtra(isInserted:)` immediately; persistence is handled centrally
    /// by `SettingsView`.
    @Binding var settings: AdrafinilSettings
    var setup: any SetupProviding = LiveSetupProvider()
    var device: DeviceCapabilities = .current

    @State private var showUninstallConfirm = false

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

            // Lid-close behavior only makes sense on a portable. On a desktop Mac these controls
            // are hidden and a note explains why.
            if device.hasLid {
                Section {
                    Toggle("Play a sound when you close the lid", isOn: $settings.soundOnLidClose)
                    LabeledContent("Volume") {
                        Slider(
                            value: $settings.soundVolume,
                            in: 0 ... 1,
                            minimumValueLabel: Image(systemName: "speaker.fill")
                                .imageScale(.small).foregroundStyle(.secondary),
                            maximumValueLabel: Image(systemName: "speaker.wave.3.fill")
                                .imageScale(.small).foregroundStyle(.secondary),
                        ) {
                            Text("Volume")
                        }
                        .frame(maxWidth: 220)
                    }
                    .disabled(!settings.soundOnLidClose)
                    LabeledContent("Sound") {
                        HStack(spacing: Theme.Space.sm) {
                            Picker("Sound", selection: $settings.chimeName) {
                                ForEach(chimeOptions, id: \.id) { option in
                                    Text(option.label).tag(option.id)
                                }
                            }
                            .labelsHidden()
                            // Hear the cue without closing the lid; the picker also previews on change.
                            Button {
                                ChimePreviewPlayer.shared.preview(
                                    volume: settings.soundVolume, chimeName: settings.chimeName,
                                )
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Hear this sound")
                        }
                    }
                    .disabled(!settings.soundOnLidClose)
                    .onChange(of: settings.chimeName) { _, name in
                        ChimePreviewPlayer.shared.preview(volume: settings.soundVolume, chimeName: name)
                    }

                    Toggle("Lock the screen when you close the lid", isOn: $settings.lockOnLidClose)
                } header: {
                    Text("When you close the lid")
                } footer: {
                    Text("These apply when an agent is still working as you close the lid — a sound to confirm your Mac is staying awake, and a locked screen to keep it private.")
                }
            }

            if device.isDesktop {
                Section {
                    Label("This looks like a desktop Mac", systemImage: "desktopcomputer")
                        .font(.callout)
                } footer: {
                    Text("Adrafinil keeps it awake while your agents work — a desktop still sleeps on idle and would stall a long task. Lid and battery features are hidden because there's no lid or battery to manage.")
                }
            }

            Section {
                Button("Uninstall and quit…", role: .destructive) { showUninstallConfirm = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .focusEffectDisabled()
            } footer: {
                Text("Disconnects Adrafinil from every agent, turns off its background services, removes the adrafinil command, and deletes its settings — then quits.")
            }
        }
        .formStyle(.grouped)
        .alert("Uninstall Adrafinil?", isPresented: $showUninstallConfirm) {
            Button("Uninstall and Quit", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects Adrafinil from all your agents, turns off its background services, and removes the adrafinil command and its settings. This can't be undone.")
        }
    }

    private func performUninstall() {
        Task {
            await setup.uninstallEverything()
            // Everything is already torn down (the sleep block was released first), so exit the process
            // directly. Routing through `NSApp.terminate` would hit the quit gate, which tries to reach
            // the daemon we just unregistered — with no daemon to answer, that wedges the quit.
            exit(0)
        }
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
                Text("Turn an agent on and Adrafinil keeps your Mac awake while it's working, then lets it sleep again when the agent stops. Turn it off to disconnect. Some agents can also keep your Mac awake on their own — that adds Adrafinil as an MCP tool they can call.")
            }

            Section {
                Button("Open setup again…") {
                    (NSApp.delegate as? AppDelegate)?.presentInstaller()
                }
                // Keep this out of the form's initial focus: as the only plain button it otherwise
                // lands the first-responder ring, making a secondary utility read as the main action.
                .focusEffectDisabled()
            } footer: {
                Text("Reopens the guided setup. Use it to connect a new agent, or to fix one that shows “Needs reconnect”.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshRows() }
    }

    private func refreshRows() {
        agentRows = agentHooks.detectedAgents().map { kind in
            AgentRowModel(
                kind: kind,
                installState: agentHooks.installState(for: kind),
                mcpSupported: agentHooks.mcpSupported(for: kind),
                mcpState: agentHooks.mcpState(for: kind),
            )
        }
    }
}

/// View-model for a single agent row in the Agents tab.
struct AgentRowModel: Identifiable {
    let kind: AgentKind
    var installState: HookInstallState
    /// Whether this agent can host Adrafinil's MCP hold tool (verified agents only).
    var mcpSupported: Bool
    /// Registration state of the MCP hold tool, independent of the hook `installState`.
    var mcpState: HookInstallState
    var id: AgentKind {
        kind
    }
}

private struct AgentInstallRow: View {
    @Binding var model: AgentRowModel
    let agentHooks: any AgentHooksProviding
    let onChange: () -> Void

    private var isInstalled: Bool {
        model.installState == .installed
    }
    private var mcpInstalled: Bool {
        model.mcpState == .installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Text(model.kind.displayName).font(.toolName)

                Spacer(minLength: Theme.Space.md)

                stateChip

                Button { agentHooks.revealConfig(for: model.kind) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show \(model.kind.displayName)'s settings file in Finder")

                Toggle("", isOn: Binding(
                    get: { isInstalled },
                    set: { newValue in
                        if newValue {
                            try? agentHooks.install(for: model.kind)
                        } else {
                            try? agentHooks.uninstall(for: model.kind)
                        }
                        onChange()
                    },
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if model.installState == .modifiedExternally { reconnectNote }

            if model.mcpSupported { mcpToggle }
        }
    }

    /// Shown when the agent's config was edited outside Adrafinil so it no longer matches what we
    /// wrote. Re-installing overwrites the entry with the canonical form, restoring the connection.
    private var reconnectNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("\(model.kind.displayName)'s Adrafinil hook isn't in the form Adrafinil expects — likely edited by hand or left over from an update — so it may not notice when \(model.kind.displayName) is working and keep your Mac awake. Reconnect restores it without touching your other \(model.kind.displayName) settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            Button("Reconnect") {
                try? agentHooks.install(for: model.kind)
                onChange()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
    }

    /// Secondary, indented control: registers Adrafinil's MCP hold tool with this agent so it can
    /// keep the Mac awake on its own. Independent of the hook toggle above — an agent can have the
    /// hold tool without session tracking, or vice versa.
    private var mcpToggle: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Let it keep your Mac awake on its own")
                    .font(.subheadline)
                Text("Adds Adrafinil as an MCP tool in \(model.kind.displayName), so the agent can keep your Mac awake for work that runs past its reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Space.md)

            Toggle("", isOn: Binding(
                get: { mcpInstalled },
                set: { newValue in
                    if newValue {
                        try? agentHooks.installMCP(for: model.kind)
                    } else {
                        try? agentHooks.uninstallMCP(for: model.kind)
                    }
                    onChange()
                },
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.leading, Theme.Space.md)
    }

    /// Only the two states the toggle can't convey on its own get a chip: a reassuring "Connected"
    /// when healthy, and a "Needs attention" warning when the config drifted. A plain off agent
    /// shows nothing — the off switch already says it.
    @ViewBuilder
    private var stateChip: some View {
        switch model.installState {
        case .installed:
            StateChip(text: "Connected", systemImage: "checkmark.circle.fill", tint: Theme.ok)
        case .notInstalled:
            EmptyView()
        case .modifiedExternally:
            StateChip(text: "Needs reconnect", systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
        }
    }
}

// MARK: - Safety tab

struct SafetySettingsTab: View {
    @Binding var settings: AdrafinilSettings
    var device: DeviceCapabilities = .current

    var body: some View {
        Form {
            Section("Thermal cutout") {
                Toggle(
                    "Force sleep when CPU temperature is too high",
                    isOn: $settings.thermalCutoutEnabled,
                )
                LabeledContent("Threshold") {
                    HStack(spacing: Theme.Space.sm) {
                        Slider(value: $settings.thermalThresholdCelsius, in: 70 ... 95, step: 1)
                            .frame(maxWidth: 180)
                        Text("\(Int(settings.thermalThresholdCelsius))°C")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.thermalCutoutEnabled)
            }

            // No battery to drain on a desktop Mac, so the low-battery cutout is hidden there.
            if device.hasBattery {
                Section("Low-battery cutout") {
                    Toggle(
                        "Force sleep when battery runs low (on battery, lid closed)",
                        isOn: $settings.lowBatteryCutoutEnabled,
                    )
                    LabeledContent("Threshold") {
                        HStack(spacing: Theme.Space.sm) {
                            Slider(value: Binding(
                                get: { Double(settings.lowBatteryThresholdPercent) },
                                set: { settings.lowBatteryThresholdPercent = Int($0) },
                            ), in: 5 ... 50, step: 1)
                                .frame(maxWidth: 180)
                            Text("\(settings.lowBatteryThresholdPercent)%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(!settings.lowBatteryCutoutEnabled)
                }
            }

            Section {
                Toggle(
                    "Stop waiting on agents that go quiet",
                    isOn: $settings.idleReleaseEnabled,
                )
                Stepper(value: $settings.idleReleaseSeconds, in: 30 ... 600, step: 30) {
                    LabeledContent("Consider quiet after", value: Self.friendlyDuration(settings.idleReleaseSeconds))
                }
                .disabled(!settings.idleReleaseEnabled)
            } header: {
                Text("Idle agents")
            } footer: {
                Text("If an agent does nothing for a while, Adrafinil stops keeping your Mac awake for it — so a stuck or crashed agent can't hold it up forever.")
            }

            Section {
                Toggle(
                    "Notice other agents while one is active",
                    isOn: $settings.processSniffingEnabled,
                )
                .help("Agents that run as one shared background service, like Hermes, aren't picked up this way — connect them in the Agents tab so their hooks can signal when they're actually working.")
                Toggle(
                    "Keep the Mac awake for them too",
                    isOn: $settings.autoAcquireForKnownAgents,
                )
                .disabled(!settings.processSniffingEnabled)
            } header: {
                Text("Finding agents")
            } footer: {
                Text("A backup to the per-agent setup: while Adrafinil is already keeping your Mac awake for one agent, it can also notice other known agents (like a second Claude Code) running without their hook installed. It only runs while an agent is already active — never a background scan — so it costs nothing while your Mac is idle or asleep.")
            }

            Section {
                Toggle(
                    "Let agents keep your Mac awake on their own",
                    isOn: $settings.agentHoldsEnabled,
                )
                Stepper(value: $settings.manualHoldMaxHours, in: 1 ... 12, step: 1) {
                    LabeledContent(
                        "Longest a hold can last",
                        value: "\(Int(settings.manualHoldMaxHours)) \(Int(settings.manualHoldMaxHours) == 1 ? "hour" : "hours")",
                    )
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

    /// A human-facing rendering of the idle-release interval: "30 sec", "1 min", "1 min 30 sec",
    /// "5 min" — never the developer-facing "300s". Zero-valued units are dropped automatically.
    private static func friendlyDuration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}

// MARK: - About tab

struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AdrafinilConstants.marketingVersion
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()

            SpiralEyeView(closedness: 0, color: Theme.awake, pupilColor: Theme.onAwake, variant: .panel)
                .frame(width: 96, height: 56)

            VStack(spacing: Theme.Space.xs) {
                Text("Adrafinil").font(.system(.title, design: .rounded).weight(.semibold))
                Text("Version \(appVersion)").font(.callout).foregroundStyle(.secondary)
            }

            Text("Keep your Mac awake only while AI agents are working.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Link(
                "github.com/kageroumado/adrafinil",
                destination: URL(string: "https://github.com/kageroumado/adrafinil")!,
            )
            .font(.callout)

            Spacer()

            Text("MIT License · © 2026 kageroumado")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer().frame(height: Theme.Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Settings · General") {
        @Previewable @State var settings = AdrafinilSettings()
        SettingsView(
            appSettings: $settings,
            agentHooks: PreviewAgentHooksProvider(),
            setup: PreviewSetupProvider(),
        )
        .frame(width: 520, height: 560)
    }
    #Preview("Settings · General (desktop)") {
        @Previewable @State var settings = AdrafinilSettings()
        GeneralSettingsTab(
            settings: $settings,
            setup: PreviewSetupProvider(),
            device: DeviceCapabilities(hasLid: false, hasBattery: false),
        )
        .frame(width: 520, height: 560)
    }
    #Preview("Settings · Safety (desktop)") {
        @Previewable @State var settings = AdrafinilSettings()
        SafetySettingsTab(
            settings: $settings,
            device: DeviceCapabilities(hasLid: false, hasBattery: false),
        )
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
        AboutTab()
            .frame(width: 520, height: 560)
    }
#endif
