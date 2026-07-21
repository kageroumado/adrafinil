#if DEBUG
    import AdrafinilShared
    import SwiftUI

    /// DEBUG-only control room. Switch the menu-bar popover between mock scenarios (the real popover and
    /// the live preview here both update), trigger the floating "while you were away" panel, and open
    /// the installer/settings — all without a running daemon. Auto-opens on launch in DEBUG builds.
    struct DebugControlPanel: View {
        @Bindable var control: DebugControl

        private var appDelegate: AppDelegate? {
            control.appDelegate ?? (NSApp.delegate as? AppDelegate)
        }
        @Environment(\.openSettings) private var openSettings
        @State private var showCodexTrust = false

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                controls
                    .frame(width: 300)
                    .padding(Theme.Space.lg)

                Divider()

                livePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(minWidth: 720, minHeight: 560)
            .sheet(isPresented: $showCodexTrust) {
                CodexTrustView(
                    readStatus: { control.statusModel?.codexTrustStatus ?? .untrusted },
                    primaryTitle: "Done",
                    onPrimary: { showCodexTrust = false },
                )
                .padding(Theme.Space.xl + Theme.Space.sm)
                .frame(minWidth: 460)
            }
        }

        // MARK: - Controls

        private var controls: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Debug Controls")
                        .font(.system(.title2, design: .rounded).weight(.bold))

                    GroupBox("Menu-bar status") {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Picker("Scenario", selection: $control.popover) {
                                ForEach(PopoverScenario.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)

                            Toggle("Use live daemon instead", isOn: $control.useLiveDaemon)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Text("Click the menu-bar sun icon to see the real popover, or watch the preview →")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Attention (menu-bar badge + cards)") {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Picker("Attention", selection: $control.attention) {
                                ForEach(AttentionScenario.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            Text("Forces the menu-bar eye's badge and the popover's attention cards. Watch the real menu-bar icon and the preview →")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button {
                                showCodexTrust = true
                            } label: {
                                Label("Open Codex trust page", systemImage: "lock.shield")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("\u{201C}While you were away\u{201D} panel") {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            ForEach(AwayScenario.allCases) { scenario in
                                Button {
                                    AwayNotifier.shared.deliver(scenario.summary)
                                } label: {
                                    Label(scenario.title, systemImage: "rectangle.topthird.inset.filled")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Pre-sleep cue") {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            sleepCueButton("Agents finished", cause: .workComplete)
                            sleepCueButton("Hold expired", cause: .holdExpired)
                            sleepCueButton("Safety cutout", cause: .safetyCutout)
                            sleepCueButton("Released by you (remote)", cause: .userAction)
                            Text("Plays what the daemon would play as the lid-closed Mac goes back to sleep, honoring the current Settings (sound choice, volume, toggles).")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Windows & flows") {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Button {
                                appDelegate?.presentInstallerPreview()
                            } label: {
                                Label("Open setup / installer flow", systemImage: "wand.and.stars")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                openSettings()
                            } label: {
                                Label("Open Settings window", systemImage: "gearshape")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                appDelegate?.presentGallery()
                            } label: {
                                Label("Open static gallery", systemImage: "square.grid.2x2")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                appDelegate?.presentMenuWindow()
                            } label: {
                                Label("Open fallback menu window", systemImage: "macwindow")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Installer & Settings open with mock providers — walking them changes nothing on disk or in the system.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .onChange(of: control.popover) { control.apply() }
            .onChange(of: control.useLiveDaemon) { control.apply() }
            .onChange(of: control.attention) { control.applyAttention() }
        }

        /// Auditions a cause through the real `SleepCueDecider` against the on-disk settings,
        /// as if the lid were closed — so a per-cause "Off" or a disabled master toggle is
        /// audible (as silence) here too, exactly like on the daemon.
        private func sleepCueButton(_ title: String, cause: ReleaseCause) -> some View {
            Button {
                let settings = AdrafinilSettings.load()
                let decision = SleepCueDecider().onSleepResuming(
                    cause: cause, lidClosed: true, settings: settings,
                )
                guard let soundName = decision.soundName else { return }
                ChimePreviewPlayer.shared.preview(
                    volume: settings.soundVolume,
                    soundName: soundName,
                    cue: decision.cue ?? .sleepWorkComplete,
                )
            } label: {
                Label(title, systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        // MARK: - Live preview

        private var livePreview: some View {
            VStack(spacing: Theme.Space.md) {
                Text("Live menu-bar popover").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let model = control.statusModel {
                    MenuPopover(status: model)
                        .fixedSize()
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(Theme.Space.xl)
        }
    }

    #Preview("Debug Control Panel") {
        let control = DebugControl.shared
        let model = AppStatusModel(provider: MockStatusProvider())
        model.status = control.popover.status // seed for a deterministic snapshot
        control.statusModel = model
        return DebugControlPanel(control: control)
    }
#endif
