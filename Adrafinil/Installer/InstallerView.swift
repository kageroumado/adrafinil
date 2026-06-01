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
    /// Which agents should also get Adrafinil's MCP self-hold tool. A separate decision from
    /// `selected` (the session hook), mirroring Settings → Agents — defaults on for capable agents.
    @State private var mcpSelected: Set<AgentKind> = []
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
            mcpSelected = Set(detected.filter { agentHooks.mcpSupported(for: $0) })
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
                Text("Adrafinil keeps your Mac awake — even with the lid closed — while your AI agents work.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("It's fully open source —").foregroundStyle(.secondary)
                    Link("view it on GitHub", destination: Self.repoURL)
                        .focusEffectDisabled()
                }
                .font(.callout)
            }

            whatGetsInstalled

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

    /// Up-front disclosure of the three things setup puts on the system. Mirrors the uninstall
    /// summary in Settings → About, so the user sees the same components going in that they're told
    /// about coming out — important for a tool that's a menu-bar app, a background service, and a CLI.
    private var whatGetsInstalled: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("What gets set up")
                .font(.subheadline.weight(.semibold))

            installItem(
                icon: "menubar.dock.rectangle",
                title: Text("A menu bar app"),
                detail: "The controls you're looking at now — its window opens from the menu bar.")
            installItem(
                icon: "gearshape.2.fill",
                title: Text("A background helper"),
                detail: "Keeps your Mac awake while agents work. Registered as a login service so it's ready after a restart.")
            installItem(
                icon: "terminal",
                title: Text("The ") + Text("adrafinil").monospaced() + Text(" command"),
                detail: "Lets your agents tell Adrafinil when they start and stop working.")
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.Radius.inner)
    }

    private func installItem(icon: String, title: Text, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.awake)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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
            Text("Connect each agent so Adrafinil knows when it's working and keeps your Mac awake only then. Some agents can also keep it awake on their own — for a build or deploy that runs past their reply. You can change all of this later in Settings.")
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
                            AgentRow(
                                kind: kind,
                                isSelected: selected.contains(kind),
                                mcpSupported: agentHooks.mcpSupported(for: kind),
                                isMCPSelected: mcpSelected.contains(kind),
                                onToggle: { sel in
                                    if sel { selected.insert(kind) } else { selected.remove(kind) }
                                },
                                onToggleMCP: { sel in
                                    if sel { mcpSelected.insert(kind) } else { mcpSelected.remove(kind) }
                                }
                            )
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

            HStack {
                Spacer()
                // Own tight glass container so Skip and Install read as one connected control pair
                // instead of the stretched glass "bridge" they formed inside the outer container.
                GlassEffectContainer(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Button("Skip") { step = .done }.buttonStyle(.glass)
                        Button("Install") { Task { await runInstall() } }
                            .buttonStyle(.glassProminent)
                            .disabled(selected.isEmpty)
                    }
                }
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
            // The MCP self-hold tool is a separate registration, only for capable agents the user
            // left enabled. Independent of the hook above, but only meaningful once connected.
            if agentHooks.mcpSupported(for: agent), mcpSelected.contains(agent) {
                do {
                    try agentHooks.installMCP(for: agent)
                    installLog.append("[\(agent.displayName)] self-hold enabled")
                } catch {
                    installLog.append("[\(agent.displayName)] self-hold: \(error.localizedDescription)")
                }
            }
        }
        await setup.symlinkCLI()
        step = .done
    }
}

/// A detected-agent row. The top line connects the session hook (Adrafinil tracks when the agent
/// works); MCP-capable agents get an indented sub-toggle for the self-hold tool, mirroring
/// Settings → Agents so the two surfaces use identical language. Only shown for detected agents.
struct AgentRow: View {
    let kind: AgentKind
    let isSelected: Bool
    let mcpSupported: Bool
    let isMCPSelected: Bool
    let onToggle: (Bool) -> Void
    let onToggleMCP: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Text(kind.displayName).font(.toolName)
                Spacer(minLength: Theme.Space.md)
                Toggle("", isOn: Binding(get: { isSelected }, set: { onToggle($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if mcpSupported { mcpSubRow }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    /// Indented secondary control: registers Adrafinil's MCP self-hold tool. Disabled (and dimmed)
    /// until the agent is connected above — MCP without a connection isn't a meaningful setup choice.
    private var mcpSubRow: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Let it keep your Mac awake on its own")
                    .font(.subheadline)
                Text("Adds Adrafinil as an MCP tool in \(kind.displayName), so it can keep your Mac awake for work that runs past its reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.md)
            Toggle("", isOn: Binding(get: { isMCPSelected }, set: { onToggleMCP($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.leading, Theme.Space.md)
        .disabled(!isSelected)
        .opacity(isSelected ? 1 : 0.45)
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
