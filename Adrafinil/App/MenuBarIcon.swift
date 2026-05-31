import SwiftUI
import AdrafinilShared

/// Menu-bar icon with three states:
///
/// - **Idle** — grayscale outlined moon, no badge.
/// - **Active** — orange/yellow filled sun, with a count badge when count > 1.
/// - **Cutout** — a red warning icon shown for 30 s after a thermal (exclamation
///   triangle) or low-battery (battery) cutout event, then auto-reverts to idle. The
///   revert is driven by a `Task` that sleeps until the 30-second boundary, ensuring
///   the icon updates without waiting for the next 2-second status poll.
struct MenuBarIcon: View {
    let status: AppStatusModel

    /// Bumped by the revert task to force a re-render after the 30-second window.
    @State private var revertTick: UInt = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch currentState {
            case .idle:
                Image(systemName: "moon")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.secondary)

            case .active(let count):
                Image(systemName: "sun.max.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Theme.awake)
                    .overlay(alignment: .topTrailing) {
                        if count > 1 {
                            Text("\(count)")
                                .font(.system(size: 7, weight: .bold))
                                .padding(2)
                                .background(Theme.awake, in: Circle())
                                .foregroundStyle(.white)
                                .offset(x: 4, y: -4)
                        }
                    }

            case .thermalCutout:
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.red)

            case .lowBatteryCutout:
                Image(systemName: "battery.25percent")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.red)
            }
        }
        .task(id: cutoutTaskID) {
            await scheduleRevert()
        }
    }

    // MARK: - State machine

    private enum IconState: Equatable {
        case idle
        case active(count: Int)
        case thermalCutout
        case lowBatteryCutout
    }

    /// Reads `revertTick` so that bumping it in `scheduleRevert` triggers a body re-evaluation.
    private var currentState: IconState {
        _ = revertTick
        guard let s = status.status else { return .idle }

        if let at = s.lastEventAt, Date().timeIntervalSince(at) < 30 {
            if s.lastEvent == .thermalCutout { return .thermalCutout }
            if s.lastEvent == .lowBatteryCutout { return .lowBatteryCutout }
        }

        if s.isBlocking {
            return .active(count: s.assertions.count)
        }

        return .idle
    }

    // MARK: - Revert task

    /// True for the cutout events that get the transient red icon.
    private static func isCutout(_ event: DaemonEvent?) -> Bool {
        event == .thermalCutout || event == .lowBatteryCutout
    }

    /// A stable identity for the `.task(id:)` modifier; changes only when a fresh
    /// cutout event arrives (new `lastEventAt` timestamp).
    private var cutoutTaskID: Date {
        guard Self.isCutout(status.status?.lastEvent),
              let at = status.status?.lastEventAt else { return .distantPast }
        return at
    }

    /// Sleeps until the 30-second cutout window expires, then bumps `revertTick` to force a
    /// re-render. Cancelled automatically if a new `cutoutTaskID` value arrives (via the
    /// `.task(id:)` identity mechanism).
    @MainActor
    private func scheduleRevert() async {
        guard Self.isCutout(status.status?.lastEvent),
              let at = status.status?.lastEventAt else { return }
        let remaining = max(0, 30.05 - Date().timeIntervalSince(at))
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
        revertTick &+= 1
    }
}
