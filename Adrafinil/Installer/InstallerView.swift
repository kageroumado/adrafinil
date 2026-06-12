import AdrafinilShared
import SwiftUI

struct InstallerView: View {
    let setup: any SetupProviding
    let agentHooks: any AgentHooksProviding

    init(
        setup: any SetupProviding = LiveSetupProvider(),
        agentHooks: any AgentHooksProviding = LiveAgentHooksProvider(),
        initialStep: Step = .helper,
        previewInstalling: Bool = false,
    ) {
        self.setup = setup
        self.agentHooks = agentHooks
        self._step = State(initialValue: initialStep)
        self._isInstalling = State(initialValue: previewInstalling)
    }

    @State private var detected: Set<AgentKind> = []
    @State private var selected: Set<AgentKind> = []
    /// Which agents should also get Adrafinil's MCP self-hold tool. A separate decision from
    /// `selected` (the session hook), mirroring Settings → Agents — defaults on for capable agents.
    @State private var mcpSelected: Set<AgentKind> = []
    @State private var step: Step = .helper
    @State private var helperErrors: [String] = []
    @State private var needsApproval = false
    @State private var registering = false
    @State private var window: NSWindow?

    /// Drives the install choreography: once true, the agent list collapses to just the selected
    /// agents, each row shows live status instead of its toggles, and the footer morphs into a
    /// progress bar.
    @State private var isInstalling = false
    /// Per-agent install status, filled in as `runInstall` walks the selected agents in order.
    @State private var phases: [AgentKind: InstallPhase] = [:]
    /// Set when the success step appears, to spring the seal in.
    @State private var sealPopped = false

    enum Step { case helper, agents, done }

    /// A connecting agent's live status during the install choreography.
    enum InstallPhase: Equatable { case pending, installing, done, failed }

    /// Fraction of the selected agents that have finished (done or failed). Drives the progress bar.
    private var installProgress: Double {
        guard !selected.isEmpty else { return 0 }
        let finished = phases.values.count(where: { $0 == .done || $0 == .failed })
        return Double(finished) / Double(selected.count)
    }

    /// How one setup step gives way to the next: the new step fades and scales up into place while
    /// the old one fades out — a gentle morph rather than a hard cut (used for agents → done).
    private static let stepTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96)),
        removal: .opacity,
    )

    private static let repoURL = URL(string: "https://github.com/kageroumado/adrafinil")!

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                switch step {
                case .helper: helperStep.transition(Self.stepTransition)
                case .agents: agentsStep.transition(Self.stepTransition)
                case .done: doneStep.transition(Self.stepTransition)
                }
            }
            .padding(Theme.Space.xl + Theme.Space.sm)
        }
        .background(WindowAccessor { window = $0 })
        .onAppear {
            detected = Set(agentHooks.detectedAgents())
            selected = detected
            mcpSelected = Set(detected.filter { agentHooks.mcpSupported(for: $0) })
            // Preview-only: seed a mid-install snapshot so the installing layout is inspectable.
            if isInstalling {
                let ordered = AgentKind.allCases.filter { selected.contains($0) }
                if ordered.indices.contains(0) { phases[ordered[0]] = .done }
                if ordered.indices.contains(1) { phases[ordered[1]] = .installing }
            }
        }
        // When approval is pending we send the user to System Settings → Login Items, which opens
        // over us. Slide our window to the left edge so the two sit side by side instead.
        .onChange(of: needsApproval) { _, pending in
            if pending { moveWindowToLeft() }
        }
        // While approval is pending, poll for it so the flow advances the moment the user flips
        // the toggle in System Settings — without this, someone who denies (or forgets) can walk
        // the rest of setup and end at "Adrafinil is set up" with neither service enabled.
        .task(id: needsApproval) {
            guard needsApproval else { return }
            while !Task.isCancelled, needsApproval {
                if setup.servicesEnabled() {
                    withAnimation(.smooth) {
                        needsApproval = false
                        step = .agents
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Gatekeeper runs a quarantined app from a randomized, ephemeral translocation point.
    /// Setting up from there would bake that path — gone at the next launch — into every hook,
    /// the CLI symlink, and the service registrations.
    private var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
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
            SpiralEyeView(closedness: 0, color: Theme.awake, pupilColor: Theme.onAwake, variant: .panel)
                .frame(width: 88, height: 52)
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

            if isTranslocated {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("Move Adrafinil to Applications first", systemImage: "arrow.down.app.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.warn)
                    Text("Adrafinil is running from a temporary location (macOS translocation). Setting up from here would point everything at a path that disappears on the next launch. Move Adrafinil.app to your Applications folder, then open it again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: Theme.Radius.inner)
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
                .disabled(registering || isTranslocated)
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
                detail: "The controls you're looking at now — its window opens from the menu bar.",
            )
            installItem(
                icon: "gearshape.2.fill",
                title: Text("A background helper"),
                detail: "Keeps your Mac awake while agents work. Registered as a login service so it's ready after a restart.",
            )
            installItem(
                icon: "terminal",
                title: Text("The \(Text("adrafinil").monospaced()) command"),
                detail: "Lets your agents tell Adrafinil when they start and stop working.",
            )
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
                needsApproval = true // stay here, show guidance, wait for the user to approve
            } else {
                step = .agents
            }
        }
    }

    // MARK: - Step 2 · agents

    private var agentsStep: some View {
        // Only agents we actually found — connecting one that isn't installed is meaningless, and
        // a long greyed-out list is just noise. Undetected ones can be connected later in Settings.
        // Once installing, the list collapses to just the agents being connected.
        let detectedAgents = AgentKind.allCases.filter { detected.contains($0) }
        let agents = isInstalling ? detectedAgents.filter { selected.contains($0) } : detectedAgents
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
                                phase: isInstalling ? (phases[kind] ?? .pending) : nil,
                                onToggle: { sel in
                                    if sel { selected.insert(kind) } else { selected.remove(kind) }
                                },
                                onToggleMCP: { sel in
                                    if sel { mcpSelected.insert(kind) } else { mcpSelected.remove(kind) }
                                },
                            )
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .glassCard(cornerRadius: Theme.Radius.inner)
                }
                .frame(maxHeight: 240)
            }

            Spacer(minLength: Theme.Space.md)

            if isInstalling {
                ProgressView(value: installProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.awake)
                    .transition(.opacity)
            }

            installFooter
                .controlSize(.large)
        }
    }

    /// Bottom controls for the agents step. In selection mode it's the Skip/Install pair; once
    /// installing, Skip slides away and the prominent button stretches full-width and morphs into a
    /// "Connecting…" capsule — the same control growing into the progress affordance.
    private var installFooter: some View {
        // Own tight glass container so Skip and Install read as one connected control pair instead
        // of the stretched glass "bridge" they'd form inside the outer container.
        GlassEffectContainer(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                if !isInstalling {
                    Spacer()
                    Button("Skip") {
                        // Skipping the agents only skips the agents — the CLI command was
                        // promised on the first step and is still set up.
                        Task { await setup.symlinkCLI() }
                        withAnimation(.smooth) { step = .done }
                    }
                    .buttonStyle(.glass)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                }
                Button { Task { await runInstall() } } label: {
                    if isInstalling {
                        HStack(spacing: Theme.Space.sm) {
                            ProgressView().controlSize(.small).tint(Theme.onAwake)
                            Text("Connecting your agents…")
                        }
                        .foregroundStyle(Theme.onAwake)
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Install")
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.awake)
                .disabled(isInstalling || selected.isEmpty)
                .frame(maxWidth: isInstalling ? .infinity : nil)
            }
        }
    }

    // MARK: - Step 3 · done

    private var doneStep: some View {
        VStack(alignment: .center, spacing: Theme.Space.lg) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.ok)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(sealPopped ? 1 : 0.5)
                .opacity(sealPopped ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { sealPopped = true }
                    setup.didFinishSetup()
                }
            Text("Adrafinil is set up").font(.system(.title, design: .rounded).weight(.semibold))
            Text("It now lives in your menu bar. Close the lid while an agent is working — your Mac stays awake. No agent running? Sleep behaves normally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            // The captured window, not `keyWindow` — closing via the key window is a silent
            // no-op whenever this window isn't key (e.g. the user clicked elsewhere first).
            Button("Done") { (window ?? NSApp.keyWindow)?.close() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    /// Walks the selected agents in display order, animating each from pending → installing → done
    /// so the (near-instant) real work reads as a deliberate, satisfying sequence. The hooks run on
    /// the main actor; the short sleeps only pace the choreography, they don't gate the install.
    private func runInstall() async {
        let agents = AgentKind.allCases.filter { selected.contains($0) }

        // Enter installing mode: the list collapses to these agents, the footer morphs, and every
        // row starts pending. One animation so the morph and the pending states land together.
        withAnimation(.smooth(duration: 0.35)) {
            isInstalling = true
            for agent in agents {
                phases[agent] = .pending
            }
        }
        try? await Task.sleep(for: .milliseconds(300))

        for agent in agents {
            withAnimation(.smooth(duration: 0.25)) { phases[agent] = .installing }
            try? await Task.sleep(for: .milliseconds(340))

            var ok = true
            do {
                try agentHooks.install(for: agent)
                // The MCP self-hold tool is a separate registration, only for capable agents the
                // user left enabled — independent of the hook, but set up in the same beat.
                if agentHooks.mcpSupported(for: agent), mcpSelected.contains(agent) {
                    try agentHooks.installMCP(for: agent)
                }
            } catch {
                ok = false
            }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                phases[agent] = ok ? .done : .failed
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        await setup.symlinkCLI()
        // Let the last check settle and the bar reach 100% before morphing to the success step.
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.smooth(duration: 0.4)) { step = .done }
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
    /// Non-nil once installation begins: the row shows live status instead of its toggles, and the
    /// MCP sub-row collapses (its setup is folded into the single connecting beat).
    var phase: InstallerView.InstallPhase?
    let onToggle: (Bool) -> Void
    let onToggleMCP: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Text(kind.displayName).font(.toolName)
                    .foregroundStyle(phase == .pending ? .secondary : .primary)
                Spacer(minLength: Theme.Space.md)
                trailing
            }
            if mcpSupported, phase == nil { mcpSubRow }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(
            Theme.controlShape
                .fill(Theme.awake.opacity(phase == .installing ? 0.12 : 0))
                .padding(.horizontal, Theme.Space.xs),
        )
    }

    /// The trailing control: the selection toggle before install, then live status once connecting.
    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case nil:
            Toggle("", isOn: Binding(get: { isSelected }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 15))
                .foregroundStyle(.quaternary)
        case .installing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.ok)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.warn)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
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
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onResolve(window) } }
        return view
    }
    func updateNSView(_: NSView, context _: Context) {}
}

#if DEBUG
    #Preview("Installer · helper") {
        InstallerView(setup: PreviewSetupProvider(), agentHooks: PreviewAgentHooksProvider())
            .frame(width: 560, height: 600)
    }
    #Preview("Installer · needs approval") {
        InstallerView(
            setup: PreviewSetupProvider(simulateApproval: true),
            agentHooks: PreviewAgentHooksProvider(),
        )
        .frame(width: 560, height: 600)
    }
    #Preview("Installer · agents") {
        InstallerView(
            setup: PreviewSetupProvider(),
            agentHooks: PreviewAgentHooksProvider(),
            initialStep: .agents,
        )
        .frame(width: 560, height: 600)
    }
    #Preview("Installer · installing") {
        InstallerView(
            setup: PreviewSetupProvider(),
            agentHooks: PreviewAgentHooksProvider(),
            initialStep: .agents,
            previewInstalling: true,
        )
        .frame(width: 560, height: 600)
    }
#endif
