import SwiftUI
import AdrafinilShared

/// Menu-bar icon with three states (SPEC §7.1):
///
/// - **Idle** — grayscale outlined moon, no badge.
/// - **Active** — orange/yellow filled sun, with a count badge when count > 1.
/// - **Thermal cutout** — red exclamation triangle, shown for 30 s after the event,
///   then auto-reverts to idle. The revert is driven by a `Task` that sleeps until
///   the 30-second boundary, ensuring the icon updates without waiting for the
///   next 2-second status poll.
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
                    .foregroundStyle(Color.orange)
                    .overlay(alignment: .topTrailing) {
                        if count > 1 {
                            Text("\(count)")
                                .font(.system(size: 7, weight: .bold))
                                .padding(2)
                                .background(Color.orange, in: Circle())
                                .foregroundStyle(.white)
                                .offset(x: 4, y: -4)
                        }
                    }

            case .thermalCutout:
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.red)
            }
        }
        .task(id: thermalTaskID) {
            await scheduleRevert()
        }
    }

    // MARK: - State machine

    private enum IconState: Equatable {
        case idle
        case active(count: Int)
        case thermalCutout
    }

    /// Reads `revertTick` so that bumping it in `scheduleRevert` triggers a body re-evaluation.
    private var currentState: IconState {
        _ = revertTick
        guard let s = status.status else { return .idle }

        if s.lastEvent == .thermalCutout,
           let at = s.lastEventAt,
           Date().timeIntervalSince(at) < 30 {
            return .thermalCutout
        }

        if s.isBlocking {
            return .active(count: s.assertions.count)
        }

        return .idle
    }

    // MARK: - Revert task

    /// A stable identity for the `.task(id:)` modifier; changes only when a fresh
    /// thermal-cutout event arrives (new `lastEventAt` timestamp).
    private var thermalTaskID: Date {
        guard status.status?.lastEvent == .thermalCutout,
              let at = status.status?.lastEventAt else { return .distantPast }
        return at
    }

    /// Sleeps until the 30-second thermal-cutout window expires, then bumps
    /// `revertTick` to force a re-render. Cancelled automatically if a new
    /// `thermalTaskID` value arrives (via the `.task(id:)` identity mechanism).
    @MainActor
    private func scheduleRevert() async {
        guard status.status?.lastEvent == .thermalCutout,
              let at = status.status?.lastEventAt else { return }
        let remaining = max(0, 30.05 - Date().timeIntervalSince(at))
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
        revertTick &+= 1
    }
}
