#if DEBUG
import SwiftUI
import AdrafinilShared

/// DEBUG-only control room. Switch the menu-bar popover between mock scenarios (the real popover and
/// the live preview here both update), trigger the floating "while you were away" panel, and open
/// the installer/settings — all without a running daemon. Auto-opens on launch in DEBUG builds.
struct DebugControlPanel: View {
    @Bindable var control: DebugControl

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
    @Environment(\.openSettings) private var openSettings

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
    model.status = control.popover.status   // seed for a deterministic snapshot
    control.statusModel = model
    return DebugControlPanel(control: control)
}
#endif
