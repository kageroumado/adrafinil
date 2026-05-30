import SwiftUI
import AppKit
import AdrafinilShared

// MARK: - SwiftUI content

/// Content of the "While you were away" floating panel (SPEC §7.3).
struct LidOpenSummaryView: View {
    let summary: AwaySummary
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("While you were away")
                .font(.headline)

            if summary.finished.isEmpty && summary.stillActive.isEmpty {
                Text("Nothing to report.")
                    .foregroundStyle(.secondary)
            }

            ForEach(summary.finished) { agent in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(agent.displayName) finished (\(agent.duration.compactDurationString))")
                }
            }

            ForEach(summary.stillActive) { agent in
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 8))
                        .padding(.leading, 3)
                    Text("\(agent.displayName) still running")
                }
            }

            if let temp = summary.peakTemperatureCelsius {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.secondary)
                    Text("Peak CPU temp: \(Int(temp))°C")
                        .foregroundStyle(.secondary)
                }
            }

            if summary.thermalCutout {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Thermal cutout occurred")
                        .foregroundStyle(.red)
                }
            }

            if summary.lowBatteryCutout {
                HStack(spacing: 6) {
                    Image(systemName: "battery.25percent")
                        .foregroundStyle(.red)
                    Text("Low-battery cutout occurred")
                        .foregroundStyle(.red)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - Panel controller

/// Manages a borderless floating `NSPanel` that presents a `LidOpenSummaryView`.
///
/// The panel is positioned in the top-right of the primary screen and auto-dismisses
/// after 8 seconds. Present by calling `show(summary:)`; the panel removes itself
/// on dismiss or timeout.
///
/// This controller is an `NSObject` because it needs to be retained as a property.
/// Observe `AppStatusModel.awaySummary` from `AppDelegate` to trigger presentation.
@MainActor
final class LidOpenSummaryController: NSObject {
    private var panel: NSPanel?
    private var autoDismissTimer: Timer?
    private var pendingOnDismiss: (() -> Void)?

    /// Shows (or replaces) the summary panel for `summary`.
    ///
    /// `onDismiss` is called exactly once — either when the user taps Dismiss or when
    /// the 8-second auto-dismiss timer fires, whichever comes first.
    func show(summary: AwaySummary, onDismiss: @escaping () -> Void) {
        dismiss()
        pendingOnDismiss = onDismiss

        let rootView = LidOpenSummaryView(summary: summary) { [weak self] in
            self?.finishDismiss()
        }
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.backgroundColor = NSColor.windowBackgroundColor
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false

        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        p.setContentSize(size)

        position(panel: p)
        p.orderFront(nil)
        panel = p

        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishDismiss() }
        }
    }

    /// Dismisses and clears the panel without invoking the onDismiss callback.
    func dismiss() {
        pendingOnDismiss = nil
        dismissPanel()
    }

    /// Dismisses and invokes the pending onDismiss callback exactly once.
    private func finishDismiss() {
        dismissPanel()
        let callback = pendingOnDismiss
        pendingOnDismiss = nil
        callback?()
    }

    private func dismissPanel() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.close()
        panel = nil
    }

    // MARK: - Layout

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let margin: CGFloat = 16
        let origin = CGPoint(
            x: visibleFrame.maxX - panelSize.width - margin,
            y: visibleFrame.maxY - panelSize.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}
