import SwiftUI
import AdrafinilShared

struct InstallerView: View {
    var setup: any SetupProviding = LiveSetupProvider()
    var agentHooks: any AgentHooksProviding = LiveAgentHooksProvider()

    @State private var detected: Set<AgentKind> = []
    @State private var selected: Set<AgentKind> = []
    @State private var installLog: [String] = []
    @State private var step: Step = .helper
    @State private var helperErrors: [String] = []
    @State private var needsApproval = false
    @State private var registering = false

    enum Step { case helper, agents, done }

    private static let repoURL = URL(string: "https://github.com/kageroumado/adrafinil")!

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                switch step {
                case .helper:  helperStep
                case .agents:  agentsStep
                case .done:    doneStep
                }
            }
            .padding(Theme.Space.xl + Theme.Space.sm)
        }
        .onAppear {
            detected = Set(agentHooks.detectedAgents())
            selected = detected
        }
    }

    // MARK: - Step 1 · helper

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 48)).foregroundStyle(Theme.awake)
                .symbolRenderingMode(.hierarchical)
            Text("Welcome to Adrafinil").font(.system(.largeTitle, design: .rounded).weight(.semibold))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Adrafinil installs a small privileged helper so it can block clamshell sleep while your AI agents work.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("It's fully open source —").foregroundStyle(.secondary)
                    Link("view it on GitHub", destination: Self.repoURL)
                }
                .font(.callout)
            }

            if !helperErrors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("Setup couldn't register a background service", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warn)
                    ForEach(helperErrors, id: \.self) {
                        Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: Theme.Radius.inner)
            }

            if needsApproval {
                approvalCard
            }

            Spacer()
            HStack(spacing: Theme.Space.sm) {
                if needsApproval {
                    Button("Open Login Items") { setup.openLoginItems() }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button(continueTitle) {
                    if needsApproval {
                        // The services are registered; they enable once approved. Proceed to agents.
                        step = .agents
                    } else {
                        registerHelper()
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(registering)
            }
            .controlSize(.large)
        }
    }

    private var continueTitle: String {
        if registering { return "Registering…" }
        if needsApproval { return "Continue" }
        return helperErrors.isEmpty ? "Continue" : "Retry"
    }

    /// Guidance shown when SMAppService registered the services but the user must approve them in
    /// System Settings before they enable — otherwise the user is left at a just-opened Login Items
    /// pane with no idea why.
    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("One quick approval", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(Theme.awake)
            Text("System Settings → Login Items & Extensions just opened. Turn **Adrafinil** on under “Allow in the Background,” then come back and click Continue.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.Radius.inner)
    }

    private func registerHelper() {
        Task {
            registering = true
            let outcomes = await setup.installHelper()
            registering = false
            helperErrors = outcomes.compactMap { outcome in
                outcome.failureMessage.map { "\(outcome.name): \($0)" }
            }
            guard helperErrors.isEmpty else { return }
            if outcomes.contains(where: \.requiresApproval) {
                needsApproval = true   // stay here, show guidance, wait for the user to approve
            } else {
                step = .agents
            }
        }
    }

    // MARK: - Step 2 · agents

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Connect your agents").font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Each agent you turn on lets Adrafinil know when it starts and stops working, so your Mac stays awake only while it's busy. You can change this any time in Settings.")
                .foregroundStyle(.secondary)
                .font(.callout)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Divider().padding(.leading, Theme.Space.md) }
                        AgentRow(
                            kind: kind,
                            isDetected: detected.contains(kind),
                            isSelected: selected.contains(kind)
                        ) { sel in
                            if sel { selected.insert(kind) } else { selected.remove(kind) }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
                .glassCard(cornerRadius: Theme.Radius.inner)
            }
            .frame(maxHeight: 280)

            if !installLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(installLog, id: \.self) {
                            Text($0).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.sm)
                }
                .frame(maxHeight: 96)
                .glassCard(cornerRadius: Theme.Radius.inner)
            }

            HStack {
                Spacer()
                Button("Skip") { step = .done }.buttonStyle(.glass)
                Button("Install") { Task { await runInstall() } }
                    .buttonStyle(.glassProminent)
                    .disabled(selected.isEmpty)
            }
            .controlSize(.large)
        }
    }

    // MARK: - Step 3 · done

    private var doneStep: some View {
        VStack(alignment: .center, spacing: Theme.Space.lg) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Theme.ok)
            Text("Adrafinil is set up").font(.system(.title, design: .rounded).weight(.semibold))
            Text("It now lives in your menu bar. Close the lid while an agent is working — your Mac stays awake. No agent running? Sleep behaves normally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { NSApp.keyWindow?.close() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private func runInstall() async {
        for agent in selected {
            do {
                try agentHooks.install(for: agent)
                installLog.append("[\(agent.displayName)] connected")
            } catch {
                installLog.append("[\(agent.displayName)] \(error.localizedDescription)")
            }
        }
        await setup.symlinkCLI()
        step = .done
    }
}

struct AgentRow: View {
    let kind: AgentKind
    let isDetected: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Toggle(isOn: Binding(get: { isSelected }, set: { onToggle($0) })) {
                Text(kind.displayName).font(.toolName)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!isDetected)

            Spacer()

            if isDetected {
                StateChip(text: "detected", systemImage: "dot.radiowaves.left.and.right", tint: Theme.ok)
            } else {
                StateChip(text: "not detected", tint: .secondary)
            }
            StateChip(text: "tier \(kind.tier)", tint: .secondary)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .opacity(isDetected ? 1 : 0.55)
    }
}

#if DEBUG
#Preview("Installer · helper") {
    InstallerView(setup: PreviewSetupProvider(), agentHooks: PreviewAgentHooksProvider())
        .frame(width: 560, height: 600)
}
#Preview("Installer · needs approval") {
    InstallerView(setup: PreviewSetupProvider(simulateApproval: true),
                  agentHooks: PreviewAgentHooksProvider())
        .frame(width: 560, height: 600)
}
#endif
