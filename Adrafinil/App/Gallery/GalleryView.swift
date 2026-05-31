#if DEBUG
import SwiftUI
import AdrafinilShared

/// A daemon-free gallery of every surface in every state, for live visual QA. Presented (instead of
/// the installer) when the app launches with `-ADRAFINIL_GALLERY 1`.
struct GalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Adrafinil — UI Gallery")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))

                section("Menu popover") {
                    tile("Idle") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle)) }
                    tile("One agent") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent)) }
                    tile("Many agents") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.manyAgents)) }
                    tile("Thermal cutout") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.thermalCutout)) }
                    tile("Low-battery cutout") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.lowBatteryCutout)) }
                    tile("Daemon error") { MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle, error: Fixtures.DaemonUnreachable())) }
                }

                section("\u{201C}While you were away\u{201D} notification") {
                    tile("Clean") { NotificationRecapPreview(summary: Fixtures.awayClean) }
                    tile("Active + thermal") { NotificationRecapPreview(summary: Fixtures.awayWithActiveAndCutout) }
                    tile("Low battery") { NotificationRecapPreview(summary: Fixtures.awayLowBattery) }
                }

                section("Settings") {
                    tile("Agents") {
                        SettingsView(appSettings: .constant(AdrafinilSettings()),
                                     agentHooks: PreviewAgentHooksProvider(),
                                     setup: PreviewSetupProvider())
                            .frame(width: 520, height: 440)
                    }
                }

                section("Installer") {
                    tile("Helper step") {
                        InstallerView(setup: PreviewSetupProvider(), agentHooks: PreviewAgentHooksProvider())
                            .frame(width: 520, height: 560)
                    }
                }
            }
            .padding(Theme.Space.xl + Theme.Space.sm)
        }
        .frame(minWidth: 1100, minHeight: 800)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title).font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            FlowHStack { content() }
        }
    }

    private func tile(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .padding(.bottom, Theme.Space.md)
    }
}

/// A lightweight wrapping HStack so gallery tiles flow onto multiple rows.
private struct FlowHStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 1000
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        let spacing: CGFloat = 24
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                totalHeight += rowHeight + spacing
                rows.append([]); x = 0; rowHeight = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spacing: CGFloat = 24
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Mock of the system notification banner, rendering the exact copy `AwayNotifier` produces
/// so the recap wording can be reviewed without granting notification permission.
private struct NotificationRecapPreview: View {
    let summary: AwaySummary

    var body: some View {
        let (title, body) = AwayNotifier.content(for: summary)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.awake)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 38, height: 38)
                .background(Theme.controlShape.fill(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text("ADRAFINIL").font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(width: 320, alignment: .leading)
        .glassCard()
    }
}

#Preview("Gallery") { GalleryView() }
#endif
