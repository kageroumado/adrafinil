import SwiftUI
import AdrafinilShared

struct InstallerView: View {
    let setup: any SetupProviding
    let agentHooks: any AgentHooksProviding

    init(setup: any SetupProviding = LiveSetupProvider(),
         agentHooks: any AgentHooksProviding = LiveAgentHooksProvider(),
         initialStep: Step = .helper) {
        self.setup = setup
        self.agentHooks = agentHooks
        self._step = State(initialValue: initialStep)
    }

    @State private var detected: Set<AgentKind> = []
    @State private var selected: Set<AgentKind> = []
    @State private var installLog: [String] = []
    @State private var step: Step = .helper
    @State private var helperErrors: [String] = []
    @State private var needsApproval = false
    @State private var registering = false
    @State private var window: NSWindow?

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
        .background(WindowAccessor { window = $0 })
        .onAppear {
            detected = Set(agentHooks.detectedAgents())
            selected = detected
        }
        // When approval is pending we send the user to System Settings → Login Items, which opens
        // over us. Slide our window to the left edge so the two sit side by side instead.
        .onChange(of: needsApproval) { _, pending in
            if pending { moveWindowToLeft() }
        }
    }

    private func moveWindowToLeft() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.minX + Theme.Space.lg
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: true)
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
                        .focusEffectDisabled()
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
        // Only agents we actually found — connecting one that isn't installed is meaningless, and
        // a long greyed-out list is just noise. Undetected ones can be connected later in Settings.
        let agents = AgentKind.allCases.filter { detected.contains($0) }
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Connect your agents").font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Each agent you turn on lets Adrafinil know when it starts and stops working, so your Mac stays awake only while it's busy. You can change this any time in Settings.")
                .foregroundStyle(.secondary)
                .font(.callout)

            if agents.isEmpty {
                VStack(spacing: Theme.Space.sm) {
                    Image(systemName: "binoculars").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No supported agents found yet").font(.headline)
                    Text("Install one of the supported agents, then connect it any time from Settings → Agents.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
                .glassCard(cornerRadius: Theme.Radius.inner)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(agents.enumerated()), id: \.element) { index, kind in
                            if index > 0 { Divider().padding(.leading, Theme.Space.md) }
                            AgentRow(kind: kind, isSelected: selected.contains(kind)) { sel in
                                if sel { selected.insert(kind) } else { selected.remove(kind) }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .glassCard(cornerRadius: Theme.Radius.inner)
                }
                .frame(maxHeight: 240)
            }

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
                .frame(maxHeight: 80)
                .glassCard(cornerRadius: Theme.Radius.inner)
            }

            Spacer(minLength: Theme.Space.md)

            HStack(spacing: Theme.Space.sm) {
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

/// A detected-agent row: name on the left, a switch in a consistent right-hand column. Only shown
/// for agents we actually found, so no detection/tier chrome is needed.
struct AgentRow: View {
    let kind: AgentKind
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(kind.displayName).font(.toolName)
            Spacer(minLength: Theme.Space.md)
            Toggle("", isOn: Binding(get: { isSelected }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }
}

/// Captures the hosting `NSWindow` so the installer can reposition itself (e.g. slide aside when
/// System Settings opens for approval).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onResolve(window) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
#Preview("Installer · agents") {
    InstallerView(setup: PreviewSetupProvider(),
                  agentHooks: PreviewAgentHooksProvider(),
                  initialStep: .agents)
        .frame(width: 560, height: 600)
}
#endif
