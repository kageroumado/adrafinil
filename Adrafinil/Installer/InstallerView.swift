import SwiftUI
import AdrafinilShared

struct InstallerView: View {
    @State private var detected: [AgentKind] = []
    @State private var selected: Set<AgentKind> = []
    @State private var installLog: [String] = []
    @State private var step: Step = .helper

    enum Step {
        case helper, agents, done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .helper:  helperStep
            case .agents:  agentsStep
            case .done:    doneStep
            }
        }
        .padding(28)
        .onAppear { detected = HookInstaller.detectedAgents(); selected = Set(detected) }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "moon.stars").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Welcome to Adrafinil").font(.title)
            Text("Adrafinil needs to install a small privileged helper so it can block clamshell sleep while your AI agents are working. The helper is open source — see github.com/…/adrafinil/AdrafinilHelper.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") {
                    Task {
                        await HelperInstaller.installIfNeeded()
                        step = .agents
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wire Adrafinil into your agents").font(.title2)
            Text("Each checked agent gets a SessionStart/End hook that tells Adrafinil when to keep your Mac awake. You can change this any time.")
                .foregroundStyle(.secondary)
                .font(.caption)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        AgentRow(kind: kind, isDetected: detected.contains(kind), isSelected: selected.contains(kind)) { sel in
                            if sel { selected.insert(kind) } else { selected.remove(kind) }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            if !installLog.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(installLog, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                    }
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Spacer()
                Button("Skip") { step = .done }
                Button("Install") {
                    Task { await runInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Adrafinil is set up").font(.title)
            Text("It now lives in your menu bar. Close the lid while an agent is working — your Mac will stay awake. No agent running? Sleep behaves normally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { NSApp.keyWindow?.close() }.buttonStyle(.borderedProminent)
        }
    }

    private func runInstall() async {
        let installer = HookInstaller(cliPath: CLISymlinker.installedCLIPath ?? CLISymlinker.bundledCLIPath ?? "adrafinil")
        for agent in selected {
            do {
                let result = try installer.install(for: agent, dryRun: false)
                installLog.append("[\(agent.displayName)] \(result.summary)")
            } catch {
                installLog.append("[\(agent.displayName)] \(error.localizedDescription)")
            }
        }
        await CLISymlinker.symlinkIfNeeded()
        step = .done
    }
}

struct AgentRow: View {
    let kind: AgentKind
    let isDetected: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { isSelected }, set: { onToggle($0) })) {
                HStack {
                    Text(kind.displayName)
                    if isDetected {
                        Text("detected").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                    } else {
                        Text("not detected").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("tier \(kind.tier)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!isDetected)
        }
    }
}
