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

    /// Shared so the menu-bar popover can deep-link to a specific tab (hook attention → Agents).
    @State private var nav = SettingsNavigation.shared

    var body: some View {
        @Bindable var nav = nav
        TabView(selection: $nav.selection) {
            GeneralSettingsTab(settings: $appSettings, setup: setup, device: device)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            AgentsSettingsTab(agentHooks: agentHooks)
                .tabItem { Label("Agents", systemImage: "terminal") }
                .tag(SettingsTab.agents)
            SafetySettingsTab(settings: $appSettings, device: device)
                .tabItem { Label("Safety", systemImage: "checkmark.shield") }
                .tag(SettingsTab.safety)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Single source of truth: every tab edits this one binding. Persist and propagate
        // centrally so one tab's save can't clobber a field another tab just changed, and
        // re-register the login item only when that specific toggle flips.
        .onChange(of: appSettings) { old, new in
            // Persist immediately — it's a small local write and must never be lost if the window
            // closes mid-edit.
            try? new.save()
            // Re-enabling the icon while the hidden-icon fallback window is open makes that window
            // redundant — the status item is the surface again, so dismiss it.
            if !old.showInMenuBar, new.showInMenuBar {
                AppDelegate.shared?.closeMenuWindow()
            }
            if old.launchAtLogin != new.launchAtLogin {
                Task {
                    if new.launchAtLogin {
                        try? SMAppService.mainApp.register()
                        // Verify, and reflect reality back into the toggle — a silently-failed
                        // registration would show "on" while the app never returns after reboot.
                        if SMAppService.mainApp.status != .enabled {
                            appSettings.launchAtLogin = false
                        }
                    } else {
                        try? await SMAppService.mainApp.unregister()
                    }
                }
            }
            // Flipping the background-shell opt-in applies or removes its `PreToolUse`(Bash) hook for
            // every connected, capable agent. It's a separate install path (not the core hook set),
            // so this touches only that one handler. On enable we gate on the agent being connected —
            // a background hook without the core session hooks would keep-awake for an agent the user
            // hasn't turned on; on disable we strip from all supported agents regardless (a no-op when
            // absent). Reconnects re-apply it via `LiveAgentHooksProvider.install`.
            if old.keepAwakeForBackgroundBash != new.keepAwakeForBackgroundBash {
                for kind in agentHooks.detectedAgents() where agentHooks.backgroundHoldSupported(for: kind) {
                    if new.keepAwakeForBackgroundBash {
                        if agentHooks.installState(for: kind) == .installed {
                            try? agentHooks.installBackgroundHold(for: kind)
                        }
                    } else {
                        try? agentHooks.uninstallBackgroundHold(for: kind)
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
    @State private var uninstallIssues: [String] = []
    @State private var showUninstallIssues = false
    /// Notify-only check against GitHub Releases; drives the "Check for Updates" row.
    @State private var updateCheck = UpdateCheckService()
    /// Whether the user has denied notification permission — the away recap is silently dark
    /// then, and this is the one place that says so.
    @State private var notificationsDenied = false

    private let chimeOptions: [(id: String, label: String)] = [
        ("default", "Adrafinil chime"),
        ("Submarine", "Submarine"),
        ("Ping", "Ping"),
        ("Tink", "Tink"),
        ("Glass", "Glass"),
    ]

    /// Pre-sleep cue options: same system sounds, plus a per-cause "Off" and the cause's own
    /// synthesized cue as the default.
    private let sleepCueOptions: [(id: String, label: String)] = [
        ("default", "Adrafinil cue"),
        ("Submarine", "Submarine"),
        ("Ping", "Ping"),
        ("Tink", "Tink"),
        ("Glass", "Glass"),
        ("off", "Off"),
    ]

    /// One per-cause row of the "When sleep resumes" section: a sound picker plus a preview
    /// button, previewing on change like the lid-close chime row.
    private func sleepCueRow(_ title: String, selection: Binding<String>, cue: ChimeSynth.Cue) -> some View {
        LabeledContent(title) {
            HStack(spacing: Theme.Space.sm) {
                Picker(title, selection: selection) {
                    ForEach(sleepCueOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                Button {
                    ChimePreviewPlayer.shared.preview(
                        volume: settings.soundVolume, soundName: selection.wrappedValue, cue: cue,
                    )
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Hear this sound")
            }
        }
        .disabled(!settings.sleepSoundEnabled)
        .onChange(of: selection.wrappedValue) { _, name in
            ChimePreviewPlayer.shared.preview(volume: settings.soundVolume, soundName: name, cue: cue)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !settings.showInMenuBar {
                        Text("With the icon hidden, Adrafinil keeps running in the background. Reopen it from Spotlight or Finder to bring its menu back as a window.")
                    }
                    if notificationsDenied {
                        Text("Notifications are turned off for Adrafinil in System Settings, so the “while you were away” recap won't appear after you reopen the lid.")
                    }
                }
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
                                    volume: settings.soundVolume, soundName: settings.chimeName,
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
                        ChimePreviewPlayer.shared.preview(volume: settings.soundVolume, soundName: name)
                    }

                    Toggle("Lock the screen when you close the lid", isOn: $settings.lockOnLidClose)
                } header: {
                    Text("When you close the lid")
                } footer: {
                    Text("These apply when an agent is still working as you close the lid — a sound to confirm your Mac is staying awake, and a locked screen to keep it private.")
                }

                Section {
                    Toggle("Play a sound before your Mac goes back to sleep", isOn: $settings.sleepSoundEnabled)
                    sleepCueRow("Agents finished", selection: $settings.sleepChimeWorkComplete, cue: .sleepWorkComplete)
                    sleepCueRow("Hold expired", selection: $settings.sleepChimeHoldExpired, cue: .sleepHoldExpired)
                    sleepCueRow("Safety cutout", selection: $settings.sleepChimeSafetyCutout, cue: .sleepSafetyCutout)
                    sleepCueRow("Released by you", selection: $settings.sleepChimeUserAction, cue: .sleepUserAction)
                } header: {
                    Text("When sleep resumes")
                } footer: {
                    Text("When the last agent finishes while the lid is closed, Adrafinil plays a cue just before your Mac goes back to sleep — so you know it's done without opening the lid. Each reason can have its own sound; the volume above applies.")
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
                Button {
                    if updateCheck.availableVersion != nil {
                        NSWorkspace.shared.open(updateCheck.releasesPageURL)
                    } else {
                        Task { await updateCheck.check(manual: true) }
                    }
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        if updateCheck.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Text(updateButtonTitle)
                    }
                }
                .buttonStyle(.bordered)
                .tint(updateCheck.availableVersion != nil ? .accentColor : nil)
                .disabled(updateCheck.isChecking)
                .focusEffectDisabled()
            } header: {
                Text("Updates")
            } footer: {
                Text("Adrafinil updates through GitHub Releases. This checks for a newer version and, if one's available, opens the download page — it never downloads or installs on its own.")
            }

            Section {
                Button("Uninstall and quit…", role: .destructive) { showUninstallConfirm = true }
                    // `.bordered` renders a destructive role as plain gray on macOS — prominent +
                    // red tint is what actually reads as "this deletes things".
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .focusEffectDisabled()
            } footer: {
                Text("Disconnects Adrafinil from every agent, turns off its background services, removes the adrafinil command, and deletes its settings — then quits.")
            }
        }
        .formStyle(.grouped)
        .task { notificationsDenied = await AwayNotifier.shared.authorizationDenied() }
        .task { await updateCheck.checkIfDue() }
        .alert("Uninstall Adrafinil?", isPresented: $showUninstallConfirm) {
            Button("Uninstall and Quit", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects Adrafinil from all your agents, turns off its background services, and removes the adrafinil command and its settings. This can't be undone.")
        }
        .alert("Some hooks need manual cleanup", isPresented: $showUninstallIssues) {
            Button("Quit Anyway") { exit(0) }
        } message: {
            Text("Adrafinil couldn't clean up everywhere — remove these by hand, or the agent will keep calling a command that no longer exists:\n\n\(uninstallIssues.joined(separator: "\n"))")
        }
    }

    private var updateButtonTitle: String {
        if let version = updateCheck.availableVersion { return "Update available — get version \(version)" }
        if updateCheck.isChecking { return "Checking for updates…" }
        if updateCheck.checkedUpToDate { return "You're up to date" }
        return "Check for updates"
    }

    private func performUninstall() {
        Task {
            let issues = await setup.uninstallEverything()
            // Everything is already torn down (the sleep block was released first), so exit the process
            // directly. Routing through `NSApp.terminate` would hit the quit gate, which tries to reach
            // the daemon we just unregistered — with no daemon to answer, that wedges the quit.
            guard issues.isEmpty else {
                uninstallIssues = issues
                showUninstallIssues = true
                return
            }
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
                    AppDelegate.shared?.presentInstaller()
                }
                // Keep this out of the form's initial focus: as the only plain button it otherwise
                // lands the first-responder ring, making a secondary utility read as the main action.
                .focusEffectDisabled()
            } footer: {
                Text("Reopens the guided setup. Use it to connect a new agent, or to fix one that shows “Needs reconnect”.")
            }

            // For agents Adrafinil has no built-in integration for: type a name, copy the snippets.
            ManualHookView()
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
                // Codex gates hook execution behind a `/hooks` approval; surfaced as a trust note.
                codexTrust: kind == .codex ? agentHooks.codexTrustStatus() : nil,
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
    /// Codex hook-trust status (nil for every other agent — only Codex requires the `/hooks` step).
    var codexTrust: CodexHookTrust.Status?
    var id: AgentKind {
        kind
    }
}

private struct AgentInstallRow: View {
    @Binding var model: AgentRowModel
    let agentHooks: any AgentHooksProviding
    let onChange: () -> Void

    @State private var showCodexTrust = false

    private var isInstalled: Bool {
        model.installState == .installed
    }
    private var mcpInstalled: Bool {
        model.mcpState == .installed
    }
    /// Codex is connected but the user hasn't (verifiably) trusted the hooks in `/hooks`, so Codex
    /// won't actually fire them. `.unknown` counts too: we couldn't confirm, so still nudge.
    private var codexNeedsTrust: Bool {
        isInstalled && model.kind == .codex && (model.codexTrust ?? .trusted) != .trusted
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
            if model.installState == .configUnreadable { unreadableNote }
            if codexNeedsTrust { codexTrustNote }

            if model.mcpSupported { mcpToggle }
        }
        .sheet(isPresented: $showCodexTrust, onDismiss: onChange) {
            CodexTrustView(
                readStatus: { agentHooks.codexTrustStatus() },
                primaryTitle: "Done",
                onPrimary: { showCodexTrust = false },
            )
            .padding(Theme.Space.xl + Theme.Space.sm)
            .frame(minWidth: 460)
        }
    }

    /// Codex-only: the hooks are installed but won't fire until trusted via `/hooks`. Unlike the
    /// reconnect/unreadable notes (which Adrafinil can fix by rewriting the file), trust is the user's
    /// action inside Codex, so this points them at the walkthrough rather than offering a fix button.
    private var codexTrustNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("Codex won't run these hooks until you trust them. Open Codex, run “/hooks”, and approve Adrafinil's acquire and release entries — otherwise it can't tell when Codex is working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            Button("How to trust") { showCodexTrust = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }

    /// Shown when the agent's config file exists but isn't parseable JSON (comments, a syntax
    /// error mid-edit). Adrafinil refuses to touch it — writing would replace the user's content
    /// — so connecting is blocked until the file is fixed.
    private var unreadableNote: some View {
        Text("\(model.kind.displayName)'s settings file couldn't be read (it may contain comments or a syntax error). Adrafinil won't modify it in this state — fix the file, then try connecting again.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        case .configUnreadable:
            StateChip(text: "Config unreadable", systemImage: "exclamationmark.octagon.fill", tint: Theme.warn)
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

            Section {
                Toggle(
                    "Keep the Mac awake for background shell commands",
                    isOn: $settings.keepAwakeForBackgroundBash,
                )
            } header: {
                Text("Background shell tasks")
            } footer: {
                Text("When an agent runs a shell command in the background — a long build or test run it keeps going after replying — this keeps your Mac awake for it. There's no signal when such a command finishes, so the hold lasts up to your longest-hold limit above (even if the task itself goes quiet, like a “tail -f”) and then ends on its own. Works with Claude Code. Off by default.")
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
