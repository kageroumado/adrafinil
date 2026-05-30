import SwiftUI
import AdrafinilShared
import ServiceManagement
import AppKit

struct SettingsView: View {
    /// Binding to the authoritative settings in `AdrafinilApp`.
    /// The General tab writes to this so that `MenuBarExtra(isInserted:)` reacts
    /// immediately when the user toggles "Show in menu bar".
    @Binding var appSettings: AdrafinilSettings

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: $appSettings)
                .tabItem { Label("General", systemImage: "gear") }
            AgentsSettingsTab()
                .tabItem { Label("Agents", systemImage: "terminal") }
            SafetySettingsTab(settings: $appSettings)
                .tabItem { Label("Safety", systemImage: "thermometer.medium") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
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
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            Toggle("Show in menu bar", isOn: $settings.showInMenuBar)

            Divider()

            Toggle("Sound at lid close while agents are active", isOn: $settings.soundOnLidClose)

            Group {
                HStack {
                    Text("Volume")
                    Slider(value: $settings.soundVolume, in: 0...1)
                }

                Picker("Sound", selection: $settings.chimeName) {
                    ForEach(chimeOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }
            .disabled(!settings.soundOnLidClose)

            Divider()

            Toggle("Lock the screen at lid close while agents are active", isOn: $settings.lockOnLidClose)
            Text("Keeps the Mac awake for the agent but secures it — like closing the lid normally.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Idle release minutes")
                Stepper("\(settings.idleReleaseMinutes) min",
                        value: $settings.idleReleaseMinutes, in: 1...60)
            }
        }
    }
}

// MARK: - Agents tab

struct AgentsSettingsTab: View {
    private var installer: HookInstaller {
        HookInstaller(
            cliPath: CLISymlinker.installedCLIPath ?? CLISymlinker.bundledCLIPath ?? "adrafinil"
        )
    }

    @State private var agentRows: [AgentRowModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hook installation")
                .font(.headline)
            Text("Toggle an agent to install or remove Adrafinil's hooks in that agent's config.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($agentRows) { $row in
                        AgentInstallRow(model: $row, installer: installer) {
                            refreshRows()
                        }
                    }
                    if agentRows.isEmpty {
                        Text("No supported agents detected.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .onAppear { refreshRows() }
    }

    private func refreshRows() {
        let inst = installer
        let detected = HookInstaller.detectedAgents()
        agentRows = detected.map { kind in
            AgentRowModel(kind: kind, installState: inst.installState(for: kind))
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
    let installer: HookInstaller
    let onChange: () -> Void

    private var isInstalled: Bool { model.installState == .installed }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { isInstalled },
                set: { newValue in
                    if newValue {
                        _ = try? installer.install(for: model.kind, dryRun: false)
                    } else {
                        try? installer.uninstall(for: model.kind)
                    }
                    onChange()
                }
            )) {
                Text(model.kind.displayName)
                    .frame(minWidth: 120, alignment: .leading)
            }

            Spacer()

            installStateIndicator

            Button("Reveal in Finder") { revealInFinder() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var installStateIndicator: some View {
        switch model.installState {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .notInstalled:
            Label("Not installed", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .modifiedExternally:
            Label("Modified", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private func revealInFinder() {
        let home = NSHomeDirectory()
        let candidates = agentConfigPaths(for: model.kind, home: home)
        let fm = FileManager.default
        for path in candidates {
            if fm.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
            let dir = (path as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: dir) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                return
            }
        }
    }

    private func agentConfigPaths(for kind: AgentKind, home: String) -> [String] {
        switch kind {
        case .claudeCode:  return ["\(home)/.claude/settings.json"]
        case .codex:       return ["\(home)/.codex/hooks.json"]
        case .cursor:      return ["\(home)/.cursor/hooks.json"]
        case .geminiCLI:   return ["\(home)/.gemini/settings.json"]
        case .goose:       return ["\(home)/.agents/plugins/adrafinil/hooks/hooks.json"]
        case .crush:       return ["\(home)/.config/crush/crush.json"]
        case .aider:       return ["\(home)/.zshrc"]
        case .hermes:      return ["\(home)/.hermes/plugins/adrafinil/adrafinil.py"]
        case .openCode:    return ["\(home)/.config/opencode/plugins/adrafinil.ts"]
        case .cline:       return ["\(home)/.zshrc"]
        }
    }
}

// MARK: - Safety tab

struct SafetySettingsTab: View {
    @Binding var settings: AdrafinilSettings

    var body: some View {
        Form {
            Section("Thermal cutout") {
                Toggle("Force sleep if CPU temperature exceeds threshold (while lid closed)",
                       isOn: $settings.thermalCutoutEnabled)
                HStack {
                    Text("Threshold")
                    Slider(value: $settings.thermalThresholdCelsius, in: 70...95, step: 1)
                    Text("\(Int(settings.thermalThresholdCelsius))°C")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                .disabled(!settings.thermalCutoutEnabled)
            }

            Section("Low-battery cutout") {
                Toggle("Force sleep if battery falls below threshold (on battery, while lid closed)",
                       isOn: $settings.lowBatteryCutoutEnabled)
                HStack {
                    Text("Threshold")
                    Slider(value: Binding(
                        get: { Double(settings.lowBatteryThresholdPercent) },
                        set: { settings.lowBatteryThresholdPercent = Int($0) }
                    ), in: 5...50, step: 1)
                    Text("\(settings.lowBatteryThresholdPercent)%")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                .disabled(!settings.lowBatteryCutoutEnabled)
            }

            Section("Idle release") {
                Toggle("Release assertions for processes with no recent activity",
                       isOn: $settings.idleReleaseEnabled)
                HStack {
                    Text("Idle threshold")
                    Stepper("\(settings.idleReleaseMinutes) minutes",
                            value: $settings.idleReleaseMinutes, in: 1...60)
                }
                .disabled(!settings.idleReleaseEnabled)
            }

            Section("Detection") {
                Toggle("Process-sniffing fallback (catches crashed agents)",
                       isOn: $settings.processSniffingEnabled)
                Toggle("Auto-acquire when a known agent binary starts (no hooks)",
                       isOn: $settings.autoAcquireForKnownAgents)
                    .disabled(!settings.processSniffingEnabled)
            }
        }
    }
}

// MARK: - About tab

struct AboutTab: View {
    @State private var showUninstallConfirm = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.stars")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Adrafinil \(appVersion)")
                .font(.title)

            Text("Keep your Mac awake only while AI agents are working.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("github.com/kageroumado/adrafinil",
                 destination: URL(string: "https://github.com/kageroumado/adrafinil")!)

            Text("MIT License · © 2026 kageroumado")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Built with Swift 6 and SwiftUI. Inspired by caffeinate, improved for the agent era.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()

            Button("Uninstall and quit…") {
                showUninstallConfirm = true
            }
            .foregroundStyle(.red)
        }
        .padding(24)
        .alert("Uninstall Adrafinil?", isPresented: $showUninstallConfirm) {
            Button("Uninstall and Quit", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all agent hooks, unregister the helper and daemon services, and remove the CLI symlink. This action cannot be undone.")
        }
    }

    private func performUninstall() {
        Task {
            // Clear the sleep block *before* tearing down the helper. `disablesleep` persists in the
            // power-management prefs (com.apple.PowerManagement.plist) and nothing in powerd clears
            // it on the setter's death — so once the helper is unregistered, a still-set block would
            // leave the Mac unable to sleep with no component left to fix it. forceReleaseAll drives
            // the helper to clear it and awaits that round-trip.
            try? await DaemonClient().forceReleaseAll()

            let installer = HookInstaller(
                cliPath: CLISymlinker.installedCLIPath ?? CLISymlinker.bundledCLIPath ?? "adrafinil"
            )
            for kind in AgentKind.allCases {
                try? installer.uninstall(for: kind)
            }

            try? await SMAppService.daemon(plistName: "LaunchDaemon.plist").unregister()
            try? await SMAppService.agent(plistName: "LaunchAgent.plist").unregister()

            if let path = CLISymlinker.installedCLIPath {
                try? FileManager.default.removeItem(atPath: path)
            }

            NSApp.terminate(nil)
        }
    }
}
