import AdrafinilShared
import AppKit
import ServiceManagement
import SwiftUI

/// The window-style popover attached to the menu-bar status item.
struct MenuPopover: View {
    let status: AppStatusModel
    /// Host hardware, so idle copy avoids mentioning a lid on a desktop Mac. Defaults to the real
    /// device; previews/gallery inject a desktop to exercise the variant.
    var device: DeviceCapabilities = .current

    /// Whether the in-popover quit confirmation is showing. This replaces a modal `NSAlert`, which an
    /// `.accessory` (menu-bar) app can't reliably surface — the alert appears as an off-screen system
    /// dialog and wedges the app in `runModal` waiting on a response the user can't see. An inline
    /// confirmation also keeps the choice at the cursor, where the click landed.
    @State private var confirmingQuit = false

    /// The "Keep awake" duration picker is showing (in place of the action buttons).
    @State private var pickingDuration = false
    /// Within the picker, the free-form "Custom" sub-mode (stepper + editable field) is showing.
    @State private var customMode = false
    /// The custom duration, in minutes, driven by the stepper / editable field. Defaults to 2h — the
    /// preset dropped from the row to keep it uncrowded.
    @State private var customMinutes = 120
    /// Editable text mirror of `customMinutes` ("1h 30m"), so the user can type a value directly.
    @State private var customText = "2h"
    /// The user's hold-duration cap (hours), read on appear. Bounds the presets and the custom field,
    /// and is the duration requested by "Until I turn it off".
    @State private var maxHoldHours = AdrafinilSettings().manualHoldMaxHours

    /// Preset hold durations, in minutes. Filtered to those within the user's cap before display.
    /// Longer holds are reachable via `∞` (the cap) or the custom stepper, so the row stays compact.
    private static let presetMinutes = [15, 30, 60]

    var body: some View {
        // The model's run-loop poll timer is suspended while the menu-bar popover is open, so a
        // TimelineView drives liveness instead. The per-second hold countdown is now drawn by
        // Text(timerInterval:) (system-managed), so this only needs a coarse tick — enough to
        // refresh the daemon poll, update age labels, and drop a hold from the list shortly after
        // it expires.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
                .task(id: context.date) {
                    await status.refresh()
                }
        }
        .frame(width: Theme.popoverWidth)
        // Reset the quit confirmation and the duration picker when the popover closes, so reopening
        // always lands on the status view rather than a stale prompt or a half-open picker.
        .onDisappear {
            confirmingQuit = false
            closePicker()
        }
        // Recompute connected-agent hook health each time the popover opens (a few small file reads),
        // so a drifted agent surfaces here and not only in the Agents settings tab. Also refresh the
        // hold-duration cap so the picker reflects the user's current setting.
        .task {
            status.refreshAgentHealth()
            maxHoldHours = AdrafinilSettings.load().manualHoldMaxHours
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let live = liveStatus(now: now)
        let hero = heroState(live, now: now)
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header

                // A failed poll takes precedence: if we can't reach the daemon we don't have
                // trustworthy status, so show the error rather than a stale snapshot. When we know
                // *why* it's unreachable, the problem card offers the matching fix (approve,
                // repair, or — if repair can't recover it — the manual reset).
                if status.serviceState != .ok {
                    serviceProblemCard().transition(.popoverSection)
                } else if let err = status.lastError {
                    errorCard(err).transition(.popoverSection)
                } else if let live {
                    statusCard(live, state: hero, now: now).transition(.popoverSection)

                    // The cutout state is a transient 30 s banner — no action belongs under it.
                    if hero != .cutout {
                        actionArea(state: hero).transition(.popoverSection)
                    }

                    if !status.driftedAgents.isEmpty {
                        agentDriftCard(status.driftedAgents).transition(.popoverSection)
                    }

                    if !live.warnings.isEmpty {
                        daemonWarningsCard(live.warnings).transition(.popoverSection)
                    }

                    if !live.assertions.isEmpty {
                        agentList(live.assertions, now: now).transition(.popoverSection)
                    }
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 64)
                }

                bottomBar(status.lastError == nil ? live : nil)
            }
            .padding(Theme.Space.lg)
        }
        // The quit confirmation grows out of the quit button as a warning overlay rather than swapping
        // the whole popover (which jumped its size). Anchored bottom-trailing so it appears to expand
        // from the ✕ — covering Settings and everything above — while the popover keeps its size.
        .overlay {
            if confirmingQuit {
                quitConfirmation
                    .transition(.scale(scale: 0.18, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        // Animate layout (and the window's resize) whenever the set of visible sections changes —
        // hero state, hold count, or a daemon error appearing/disappearing — so clicking "Let it
        // sleep" or an agent finishing glides the panel to its new size instead of snapping.
        .animation(.smooth(duration: 0.3), value: layoutSignature(live, hero))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: confirmingQuit)
    }

    /// A compact, order-stable key for the popover's layout: which sections are visible and how
    /// many rows the agent list has. Excludes `now`, so the 5-second tick doesn't trigger animation.
    /// Excludes `confirmingQuit` too — the confirmation is now an overlay that doesn't resize the panel.
    private func layoutSignature(_ live: DaemonStatus?, _ hero: HeroState) -> String {
        "\(pickingDuration)|\(customMode)|\(status.serviceState)|\(status.repairPhase)|\(status.lastError != nil)|\(hero)|\(live?.assertions.count ?? -1)|\(status.driftedAgents.count)|\(live?.warnings.count ?? 0)"
    }

    /// The daemon snapshot with TTL-expired holds dropped, so a hold disappears the instant its
    /// countdown hits zero rather than lingering until the daemon's next sweep. `isBlocking` is
    /// recomputed from what remains.
    private func liveStatus(now: Date) -> DaemonStatus? {
        guard var s = status.status else { return nil }
        s.assertions = s.assertions.filter { a in
            guard let exp = a.expiresAt else { return true }
            return exp > now
        }
        if s.assertions.isEmpty { s.isBlocking = false }
        return s
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Adrafinil").font(.heroTitle)
            Spacer()
            AttributionLink()
        }
    }

    // MARK: - Status card (hero)

    /// One stable card across the eye states so the spiral-eye icon keeps its view identity
    /// and *animates* between open (awake) and closed (idle / paused) instead of being
    /// swapped out; only the cutout state replaces it with a warning symbol.
    private func statusCard(_ s: DaemonStatus, state: HeroState, now _: Date) -> some View {
        let (tint, title, subtitle, dimmed): (Color, String, String, Bool) = switch state {
        case .awake:
            (Theme.awake, "Keeping your Mac awake", awakeSubtitle(s), false)
        case .cutout:
            (Theme.cutout, cutoutTitle(s), "Your Mac can sleep again", false)
        case .idle:
            (
                .secondary,
                "Sleeping normally",
                device.hasLid
                    ? "No agents active — close the lid and your Mac sleeps"
                    : "No agents active — your Mac sleeps when idle",
                true,
            )
        case .paused:
            (.secondary, "Paused", "Agents can't keep your Mac awake until you resume", false)
        }
        return heroCard(tint: tint, title: title, subtitle: subtitle, dimmed: dimmed) {
            if state == .cutout {
                Image(systemName: cutoutIcon(s))
                    .font(.system(size: 26))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            } else {
                let open = state == .awake
                // The full app-icon geometry (not the simplified menu-bar pose): the hero is
                // large enough for the eye metaphor — spiral envelope, visible dark pupil —
                // to read. Drawn larger than the 30 pt icon slot so the eye fills the card's
                // leading area instead of floating in padding; the canvas overflow is
                // transparent and the slot keeps text aligned with the other cards.
                SpiralEyeView(
                    closedness: open ? 0 : 1, color: Theme.awake, closedColor: .secondary,
                    pupilColor: Theme.onAwake, variant: .panel,
                )
                .frame(width: 48, height: 48)
                .animation(
                    open ? .spring(duration: 0.85, bounce: 0.32) : .smooth(duration: 0.8),
                    value: open,
                )
            }
        }
    }

    /// Describes what's keeping the Mac awake, distinguishing live agents from deliberate holds
    /// (e.g. "2 agents working · 1 hold").
    private func awakeSubtitle(_ s: DaemonStatus) -> String {
        let holds = s.assertions.count(where: { $0.origin == .manual })
        let agents = s.assertions.count - holds
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) \(agents == 1 ? "agent" : "agents") working") }
        if holds > 0 { parts.append("\(holds) \(holds == 1 ? "hold" : "holds")") }
        return parts.isEmpty ? "Your Mac will stay awake" : parts.joined(separator: " · ")
    }

    private func heroCard(
        tint: Color, title: String, subtitle: String, dimmed: Bool,
        @ViewBuilder icon: () -> some View,
    ) -> some View {
        HStack(spacing: Theme.Space.md) {
            icon()
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                // Always reserve two lines so a one-line subtitle (e.g. "3 agents working") and a
                // two-line one (e.g. the paused state's "Agents won't keep your Mac awake …") give
                // the card the same height — the pause/resume button below then stays put across
                // states instead of jumping.
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    // Accept the proposed (bounded) width and grow vertically to fit, so a long
                    // subtitle wraps into its reserved second line instead of being measured at its
                    // single-line ideal width and truncated ("…until you…").
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Claim all remaining width so the subtitle has the full card width to wrap into rather
            // than competing with a trailing Spacer for horizontal space.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: dimmed ? nil : tint.opacity(0.18))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 26)).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Adrafinil's helper isn't responding").font(.system(.body, design: .rounded).weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// The card shown whenever the background service is unreachable. It walks the recovery sequence:
    /// a repair in progress, the manual-reset guidance when repair couldn't recover it, or the
    /// matching first action otherwise — approve in Login Items, or run a repair (re-register).
    @ViewBuilder
    private func serviceProblemCard() -> some View {
        switch status.repairPhase {
        case .repairing:
            serviceActionCard(
                title: "Repairing Adrafinil…",
                message: "Re-registering its background services and checking they respond.",
                busy: true,
            )
        case .failed:
            // Re-registration couldn't clear the wedged records: the one remaining fix is removing
            // Adrafinil's own entry in Login Items (a targeted reset, not a system-wide one).
            serviceActionCard(
                title: "Couldn't repair Adrafinil automatically",
                message: "Open Login Items & Extensions, switch Adrafinil off and remove it with the “–” button, then reopen the app — or try repairing once more.",
                primaryTitle: "Open Login Items",
                primaryAction: { SMAppService.openSystemSettingsLoginItems() },
                secondaryTitle: "Repair Again",
                secondaryAction: { Task { await status.repair() } },
            )
        case .idle:
            switch status.serviceState {
            case .needsApproval:
                serviceActionCard(
                    title: "Adrafinil needs your approval",
                    message: "Turn Adrafinil on under “Allow in the Background” so it can keep your Mac awake while agents work. If it won't turn on, try Repair.",
                    primaryTitle: "Open Login Items",
                    primaryAction: { SMAppService.openSystemSettingsLoginItems() },
                    secondaryTitle: "Repair",
                    secondaryAction: { Task { await status.repair() } },
                )
            case .notRegistered:
                serviceActionCard(
                    title: "Adrafinil isn't set up",
                    message: "Its background service isn't registered, so it can't keep your Mac awake. Repair it to register it again.",
                    primaryTitle: "Repair",
                    primaryAction: { Task { await status.repair() } },
                )
            case .unreachable:
                serviceActionCard(
                    title: "Adrafinil's helper stopped",
                    message: "Its background service isn't responding. Repair it to re-register and bring it back.",
                    primaryTitle: "Repair",
                    primaryAction: { Task { await status.repair() } },
                )
            case .ok:
                EmptyView()
            }
        }
    }

    /// An actionable card for an unreachable background service: explains the problem and offers the
    /// fix(es). `busy` swaps the primary action for an in-progress spinner. Tinted as a warning since
    /// the Mac is silently no longer being kept awake.
    private func serviceActionCard(
        title: String,
        message: String,
        primaryTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        busy: Bool = false,
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.warn)
                    .symbolRenderingMode(.hierarchical).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if busy {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: Theme.Space.sm) {
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                    if let primaryTitle, let primaryAction {
                        Button(action: primaryAction) {
                            Text(primaryTitle).frame(maxWidth: .infinity).foregroundStyle(Theme.onAwake)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .tint(Theme.awake)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.warn.opacity(0.18))
    }

    // MARK: - Agent list

    private func agentList(_ assertions: [Assertion], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assertions.enumerated()), id: \.element.id) { index, a in
                if index > 0 { Divider().padding(.leading, Theme.Space.md) }
                AssertionRow(assertion: a, now: now) {
                    Task { await status.releaseAssertion(key: a.key) }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        // A top-level card in the popover, sibling to the hero — so it shares the hero's `card`
        // radius (the `glassCard` default), not the smaller `inner` radius meant for nesting.
        .glassCard()
    }

    // MARK: - Agent drift warning

    /// A tappable warning shown when one or more connected agents' hooks have drifted from Adrafinil's
    /// canonical form — meaning the daemon may no longer notice when they work, so the Mac quietly
    /// stops staying awake for them. Tapping opens Settings, where the Agents tab offers "Reconnect".
    private func agentDriftCard(_ agents: [AgentKind]) -> some View {
        let single = agents.count == 1
        let title = single
            ? "\(agents[0].displayName) may not be tracked"
            : "\(agents.count) agents may not be tracked"
        let subject = single ? "Its" : "Their"
        let verb = single ? "it works" : "they work"
        return SettingsLink {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.warn)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                    Text("\(subject) Adrafinil hook changed, so your Mac might not stay awake while \(verb). Open Settings to reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: Theme.warn.opacity(0.18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Degraded-protection warnings

    /// Daemon-reported notices that part of the safety net is down — a sleep block that didn't
    /// fully apply, an unreadable temperature with the thermal cutout enabled, an active cutout
    /// latch. The user is about to trust a closed lid to these; silence would be a lie.
    private func daemonWarningsCard(_ warnings: [String]) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.warn)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.warn.opacity(0.18))
    }

    // MARK: - Primary action (keep awake / pause / resume)

    /// Shown directly under the hero. Its contents depend on what's keeping the Mac up:
    /// - **idle** → a single "Keep awake" button that starts a manual hold (the on-switch the idle
    ///   state used to lack);
    /// - **awake** → "Keep awake" (add a hold) alongside "Let it sleep" (pause everything);
    /// - **paused** → "Keep your Mac awake" (resume).
    /// While the duration picker is open it replaces the buttons in place.
    @ViewBuilder
    private func actionArea(state: HeroState) -> some View {
        if pickingDuration {
            durationPicker()
        } else {
            switch state {
            case .awake:
                HStack(spacing: Theme.Space.sm) {
                    keepAwakeButton(prominent: false)
                    Button { Task { await status.setPaused(true) } } label: {
                        Text("Let it sleep").frame(maxWidth: .infinity).foregroundStyle(Theme.onAwake)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Theme.awake)
                    .help("Pause Adrafinil — your Mac sleeps normally until you resume.")
                }
            case .idle:
                keepAwakeButton(prominent: true)
            case .paused:
                Button { Task { await status.setPaused(false) } } label: {
                    Text("Keep your Mac awake").frame(maxWidth: .infinity).foregroundStyle(Theme.onAwake)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Theme.awake)
                .help("Resume Adrafinil — let agents keep your Mac awake again.")
            case .cutout:
                EmptyView()
            }
        }
    }

    /// The "Keep awake" entry point. Prominent (amber) when it's the only action — i.e. the idle
    /// state's on-switch — and glass when it sits beside "Let it sleep" in the awake state.
    @ViewBuilder
    private func keepAwakeButton(prominent: Bool) -> some View {
        let action = { withAnimation(.smooth(duration: 0.3)) { openPicker() } }
        let help = "Keep your Mac awake for a set time"
        if prominent {
            Button(action: action) {
                Text("Keep awake").frame(maxWidth: .infinity).foregroundStyle(Theme.onAwake)
            }
            .buttonStyle(.glassProminent).controlSize(.large).tint(Theme.awake).help(help)
        } else {
            Button(action: action) {
                Text("Keep awake").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large).help(help)
        }
    }

    // MARK: - Duration picker

    /// Uniform metrics so every picker control lines up exactly. The radius is concentric with the
    /// card by construction — card corner (`Theme.Radius.card`) minus the card's padding
    /// (`Theme.Space.sm`) — which `.rect(corners: .concentric)` failed to resolve for a mid-row element.
    private static let pickerControlHeight: CGFloat = 28
    /// Width of the flanking icon controls. Compact — they're now background-less, so they don't need
    /// the glass capsule's padding. The trailing slot shares this width across modes (plain pencil ⇄
    /// orange play) so it stays put.
    private static let pickerIconWidth: CGFloat = 26

    /// The inline "how long?" card revealed by "Keep awake". The ✕ (leading) and the primary button
    /// (trailing) keep their identity across modes — only the middle morphs from preset pills to the
    /// custom stepper, so the two flanking controls stay put rather than the whole row being replaced.
    /// `∞` holds until you stop it; the pencil opens the stepper.
    @ViewBuilder
    private func durationPicker() -> some View {
        HStack(spacing: Theme.Space.xs) {
            // Leading ✕ — persistent. Cancels the picker, or steps back out of custom mode.
            pickerIcon("xmark", help: customMode ? "Back to presets" : "Cancel") {
                withAnimation(.smooth(duration: 0.3)) {
                    if customMode { customMode = false } else { closePicker() }
                }
            }

            // Middle — the only part that swaps.
            if customMode {
                customStepper()
            } else {
                presetPills()
            }

            // Trailing primary — persistent slot. Pencil (open custom) ⇄ play (start the hold).
            primaryPickerButton()
        }
        .frame(height: Self.pickerControlHeight)
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    @ViewBuilder
    private func presetPills() -> some View {
        ForEach(availablePresets, id: \.self) { minutes in
            durationPill(minutes: minutes) { place(minutes: Double(minutes)) }
        }
        // `∞` — keep awake until you stop it (requests the user's cap). An SF Symbol, so it's centered
        // vertically rather than riding high like the "∞" text glyph did. Flexible width, like a pill.
        durationButton { place(minutes: maxHoldHours * 60) } label: {
            Image(systemName: "infinity").font(.system(size: 14, weight: .semibold))
        }
        .help("Keep awake until you turn it off")
    }

    @ViewBuilder
    private func customStepper() -> some View {
        HStack(spacing: 0) {
            Button { bumpCustom(-15) } label: {
                Image(systemName: "minus").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(width: 30)
            .disabled(customMinutes <= minCustomMinutes)

            // Editable: type a duration like 1h 30m. ± steps it by 15 minutes.
            TextField("", text: $customText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .onSubmit { commitCustomText() }

            Button { bumpCustom(15) } label: {
                Image(systemName: "plus").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(width: 30)
            .disabled(customMinutes >= maxCustomMinutes)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fixed-radius rounded rect (not `Capsule`) so the fill doesn't morph through a rectangle as
        // the row animates between preset and custom — see `DurationPill`.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Self.pickerControlHeight / 2, style: .continuous))
    }

    /// The trailing slot, whose identity persists across modes so it stays put: a pencil that opens the
    /// stepper, becoming an orange play that starts the hold. Both are flat (no fill) like the ✕.
    @ViewBuilder
    private func primaryPickerButton() -> some View {
        if customMode {
            pickerIcon("play.fill", tint: Theme.awake, help: "Start keeping awake") {
                commitCustomText(); place(minutes: Double(customMinutes))
            }
        } else {
            pickerIcon("pencil", help: "Custom duration") {
                withAnimation(.smooth(duration: 0.3)) { enterCustomMode() }
            }
        }
    }

    /// A flat duration choice — orange (the awake accent) numerals, no fill, so it reads as a tappable
    /// token consistent with the other background-less controls. The unit (`m`/`h`) is set smaller than
    /// the numeral via an attributed run so it reads as one token (`15m`).
    private func durationPill(minutes: Int, action: @escaping () -> Void) -> some View {
        durationButton(action: action) {
            Text(durationPillText(minutes))
        }
    }

    private func durationPillText(_ minutes: Int) -> AttributedString {
        let isHours = minutes % 60 == 0
        var number = AttributedString(isHours ? "\(minutes / 60)" : "\(minutes)")
        number.font = .system(size: 14, weight: .semibold, design: .rounded)
        var unit = AttributedString(isHours ? "h" : "m")
        unit.font = .system(size: 9.5, weight: .semibold, design: .rounded)
        return number + unit
    }

    /// A fixed-width, background-less icon control. `.secondary` for the quiet meta-actions
    /// (cancel · back · custom); `Theme.awake` for the orange play. Fixed width keeps the leading and
    /// trailing slots put across modes.
    private func pickerIcon(
        _ system: String, tint: Color = .secondary, help: String, action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.pickerIconWidth, height: Self.pickerControlHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
    }

    /// An amber-*tinted* duration pill — a light amber fill with orange content and a concentric corner
    /// radius. Lighter than a solid fill (four solids read as a wall of orange) but still a clear,
    /// bounded, tappable choice, and it echoes the hero card's amber tint. Deepens on hover for
    /// feedback. (The play button, by contrast, is a flat orange icon — see `pickerIcon`.)
    private func durationButton(
        action: @escaping () -> Void, @ViewBuilder label: @escaping () -> some View,
    ) -> some View {
        DurationPill(height: Self.pickerControlHeight, action: action, label: label)
    }

    // MARK: - Picker state & helpers

    /// Presets within the user's cap, always offering at least the smallest so the row is never empty.
    private var availablePresets: [Int] {
        let capMinutes = Int((maxHoldHours * 60).rounded())
        let within = Self.presetMinutes.filter { $0 <= capMinutes }
        return within.isEmpty ? [Self.presetMinutes[0]] : within
    }

    private var minCustomMinutes: Int { 15 }
    private var maxCustomMinutes: Int { max(minCustomMinutes, Int((maxHoldHours * 60).rounded())) }

    private func openPicker() {
        customMode = false
        pickingDuration = true
    }

    private func closePicker() {
        pickingDuration = false
        customMode = false
    }

    private func enterCustomMode() {
        customMinutes = clampCustom(customMinutes)
        customText = durationLabel(customMinutes)
        customMode = true
    }

    private func bumpCustom(_ delta: Int) {
        customMinutes = clampCustom(customMinutes + delta)
        customText = durationLabel(customMinutes)
    }

    /// Parse the editable field back into minutes, clamp to range, and re-format (reverting garbage).
    private func commitCustomText() {
        if let seconds = DurationParser.seconds(from: customText), seconds >= 60 {
            customMinutes = clampCustom(Int((seconds / 60).rounded()))
        }
        customText = durationLabel(customMinutes)
    }

    private func clampCustom(_ minutes: Int) -> Int {
        min(max(minutes, minCustomMinutes), maxCustomMinutes)
    }

    private func place(minutes: Double) {
        withAnimation(.smooth(duration: 0.3)) { closePicker() }
        Task { await status.placeHold(minutes: minutes) }
    }

    /// Text shown in the editable custom field: `45m`, `1h`, `1h 30m`.
    private func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60, mins = minutes % 60
        if hours > 0, mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    // MARK: - Quit confirmation (overlay)

    /// The quit confirmation, presented by `content` as an overlay that grows from the bottom-bar ✕
    /// (anchored bottom-trailing) rather than replacing the popover and jumping its size. It fills the
    /// popover with a warning wash; the ✕ stays in its corner but turns red, and a Cancel is added
    /// beside it (where Settings sat) so the pair is symmetric. Quitting routes through `NSApp.terminate`,
    /// which `applicationShouldTerminate` gates on pausing the daemon first — so "off" means the Mac
    /// sleeps normally again, not that the services are torn down.
    private var quitConfirmation: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                SpiralEyeView(closedness: 1, color: .secondary, variant: .panel)
                    .frame(width: 48, height: 48)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quit Adrafinil?").font(.system(.body, design: .rounded).weight(.semibold))
                    Text("Your Mac goes back to sleeping normally and agents stop being tracked until you open it again.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            // Mirror the bottom bar's trailing buttons: Cancel takes the Settings slot, the ✕ stays
            // put and turns red.
            HStack(spacing: Theme.Space.sm) {
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.sm) {
                        Button { confirmingQuit = false } label: { utilityIcon("arrow.uturn.backward") }
                            .buttonStyle(.glass)
                            .help("Cancel")
                        Button { NSApp.terminate(nil) } label: {
                            utilityIcon("xmark").foregroundStyle(.white)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .help("Quit Adrafinil")
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Same neutral gray glass as the quit button — it reads as the button's surface expanding into
        // a menu, not a separate red warning. The red lives only on the Quit button itself.
        .glassCard()
        .contentShape(.rect) // absorb taps so the status controls underneath aren't reachable
    }

    // MARK: - Bottom bar (meta + utility actions)

    /// One row: lid/temperature on the left (when known), Settings + Quit on the right.
    private func bottomBar(_ s: DaemonStatus?) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let s { metaLabels(s) }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    SettingsLink { utilityIcon("gearshape") }
                        .help("Settings…")
                    Button { confirmingQuit = true } label: {
                        // `xmark` (quit the app), not `power` — a power glyph in a Mac context
                        // reads as "shut down the Mac", the wrong mental model for closing the app.
                        utilityIcon("xmark")
                    }
                    .help("Quit Adrafinil")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    /// Lid/temperature chips. The popover is only visible while the lid is open or in
    /// clamshell (lid shut + external display), so "open" is implied — only flag clamshell.
    private func metaLabels(_ s: DaemonStatus) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if s.lidClosed {
                Label("Lid closed", systemImage: "laptopcomputer.slash")
            }
            if let temp = s.cpuTemperatureCelsius {
                if s.lidClosed { Text("·").foregroundStyle(.tertiary) }
                Label("\(Int(temp))°C", systemImage: "thermometer.medium")
                    .foregroundStyle(temp >= 80 ? Theme.cutout : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, Theme.Space.xs)
    }

    /// A glyph for the bottom-bar utility buttons (Settings / Quit), pinned to a fixed square so
    /// both `.glass` capsules come out the same size — otherwise each capsule hugs its glyph and
    /// the taller `gearshape` makes its button visibly taller than `xmark`.
    private func utilityIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 16, height: 16)
    }

    // MARK: - Derived state

    private enum HeroState { case awake, idle, cutout, paused }

    private func heroState(_ s: DaemonStatus?, now: Date) -> HeroState {
        guard let s else { return .idle }
        if s.paused { return .paused }
        if let at = s.lastEventAt, now.timeIntervalSince(at) < 30,
           s.lastEvent == .thermalCutout || s.lastEvent == .lowBatteryCutout {
            return .cutout
        }
        return s.isBlocking ? .awake : .idle
    }

    private func cutoutIcon(_ s: DaemonStatus) -> String {
        s.lastEvent == .lowBatteryCutout ? "battery.25percent" : "exclamationmark.triangle.fill"
    }
    private func cutoutTitle(_ s: DaemonStatus) -> String {
        s.lastEvent == .lowBatteryCutout ? "Low-battery cutout" : "Thermal cutout"
    }
}

// MARK: - Transitions

private extension AnyTransition {
    /// How a popover section enters/leaves as the panel resizes around it: a fade with a slight
    /// upward settle, so sections appear to grow out of / collapse into the panel rather than pop.
    static var popoverSection: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

// MARK: - AttributionLink

/// The "made by kageroumado" credit in the popover header. Reads as quiet secondary text but signals
/// it's a link with a trailing external-link arrow, and underlines on hover so the affordance is
/// unmistakable once the pointer lands on it.
private struct AttributionLink: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/kageroumado")!) {
            HStack(spacing: 2) {
                Text("made by kageroumado")
                    .underline(hovering)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - AssertionRow

struct AssertionRow: View {
    let assertion: Assertion
    /// Current time, injected from the popover's TimelineView so the countdown/age tick live while
    /// the popover is open. Defaults to now for non-timeline callers (previews).
    var now: Date = .init()
    /// Non-nil for releasable rows (agent holds). Invoked by the trailing ✕.
    var onRelease: (() -> Void)?

    /// An agent hold (`adrafinil hold` / MCP) — deliberate, reasoned, time-boxed — versus a live
    /// agent session tracked by an editor hook.
    private var isHold: Bool {
        assertion.origin == .manual
    }

    private var displayTool: String {
        AgentKind(rawValue: assertion.tool)?.displayName ?? assertion.tool
    }

    /// A hold shows the time left at minute granularity (`1h 59m`, `23m`, `<1m`) — the same word style
    /// as an agent's elapsed time, not a `1:59:59` clock; it ticks on the popover's coarse TimelineView
    /// (a per-second countdown would be noise at minute resolution). A live agent shows how long it's
    /// been working.
    private var trailingText: String {
        if isHold, let exp = assertion.expiresAt {
            let remaining = max(0, Int(exp.timeIntervalSince(now)))
            let hours = remaining / 3_600, minutes = (remaining % 3_600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            if minutes > 0 { return "\(minutes)m" }
            return "<1m"
        }
        return now.timeIntervalSince(assertion.acquiredAt).compactDurationString
    }

    var body: some View {
        // The leading mark lives on the name line so single-line rows stay vertically centered;
        // a reason, if present, indents beneath it.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.sm) {
                leadingMark
                Text(displayTool).font(.toolName)
                Spacer()
                Text(trailingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isHold, let onRelease {
                    Button(action: onRelease) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Release this hold — let the Mac sleep normally")
                }
            }
            if let reason = assertion.reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 14 + Theme.Space.sm)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.md)
    }

    /// One filled dot for every row — holds and agents alike. A single glyph keeps every mark on the
    /// same optical baseline (mixing a `pin.fill` with a dot left them visibly misaligned); the row's
    /// label and the trailing ✕ already distinguish a manual hold from a live agent.
    private var leadingMark: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(Theme.awake)
            .frame(width: 14, alignment: .leading)
    }
}

// MARK: - DurationPill

/// A light amber-tinted, capsule duration choice for the picker — a soft fill that's lighter than a
/// saturated pill yet still a clearly-bounded, tappable target. Capsule to match every other button in
/// the app (no hover state — nothing else here hovers, in line with Apple's current button design).
private struct DurationPill<Label: View>: View {
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        // A *fixed*-radius rounded rectangle, not `Capsule`: a capsule recomputes its radius from the
        // (animating) frame every tick, so during a layout transition the fill visibly morphs
        // capsule → rectangle → rounded. Pinning the radius to half the rest height keeps it a capsule
        // at rest and simply lets it extend, with no corner animation.
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        return Button(action: action) {
            label()
                .foregroundStyle(Theme.awake)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.awake.opacity(0.16), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Popover · idle") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle))
    }
    #Preview("Popover · idle (desktop)") {
        MenuPopover(
            status: AppStatusModel(previewStatus: Fixtures.idle),
            device: DeviceCapabilities(hasLid: false, hasBattery: false),
        )
    }
    #Preview("Popover · one agent") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent))
    }
    #Preview("Popover · many agents") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
    }
    #Preview("Popover · agent hold") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.withHold))
    }
    #Preview("Popover · thermal cutout") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.thermalCutout))
    }
    #Preview("Popover · agent drift") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent, driftedAgents: [.claudeCode]))
    }
    #Preview("Popover · paused") {
        var paused = Fixtures.idle
        paused.paused = true
        return MenuPopover(status: AppStatusModel(previewStatus: paused))
    }
    #Preview("Popover · daemon error") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable()))
    }
    #Preview("Popover · needs approval") {
        MenuPopover(status: AppStatusModel(
            previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable(), serviceState: .needsApproval,
        ))
    }
    #Preview("Popover · not registered") {
        MenuPopover(status: AppStatusModel(
            previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable(), serviceState: .notRegistered,
        ))
    }
    #Preview("Popover · unreachable") {
        MenuPopover(status: AppStatusModel(
            previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable(), serviceState: .unreachable,
        ))
    }
    #Preview("Popover · repairing") {
        MenuPopover(status: AppStatusModel(
            previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable(),
            serviceState: .unreachable, repairPhase: .repairing,
        ))
    }
    #Preview("Popover · repair failed") {
        MenuPopover(status: AppStatusModel(
            previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable(),
            serviceState: .unreachable, repairPhase: .failed("re-register failed"),
        ))
    }
    #Preview("Popover · many agents (dark)") {
        MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents))
            .preferredColorScheme(.dark)
    }
#endif
