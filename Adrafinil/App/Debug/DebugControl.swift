#if DEBUG
import SwiftUI
import AdrafinilShared

/// Menu-bar popover states the debug control panel can switch between.
enum PopoverScenario: String, CaseIterable, Identifiable {
    case idle, oneAgent, manyAgents, lidClosedHot, thermalCutout, lowBatteryCutout, daemonError

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .oneAgent: "One agent"
        case .manyAgents: "Many agents"
        case .lidClosedHot: "Lid closed (warm)"
        case .thermalCutout: "Thermal cutout"
        case .lowBatteryCutout: "Low-battery cutout"
        case .daemonError: "Daemon unreachable"
        }
    }

    var status: DaemonStatus {
        switch self {
        case .idle: Fixtures.idle
        case .oneAgent: Fixtures.oneAgent
        case .manyAgents: Fixtures.manyAgents
        case .lidClosedHot: Fixtures.lidClosedHot
        case .thermalCutout: Fixtures.thermalCutout
        case .lowBatteryCutout: Fixtures.lowBatteryCutout
        case .daemonError: Fixtures.idle
        }
    }

    var error: (any Error)? { self == .daemonError ? Fixtures.DaemonUnreachable() : nil }
}

/// "While you were away" panel variants the control panel can trigger.
enum AwayScenario: String, CaseIterable, Identifiable {
    case clean, activeThermal, lowBattery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "Finished cleanly"
        case .activeThermal: "Still active + thermal cutout"
        case .lowBattery: "Low-battery cutout"
        }
    }

    var summary: AwaySummary {
        switch self {
        case .clean: Fixtures.awayClean
        case .activeThermal: Fixtures.awayWithActiveAndCutout
        case .lowBattery: Fixtures.awayLowBattery
        }
    }
}

/// Shared, observable debug state. In DEBUG builds the menu-bar `AppStatusModel` is backed by a
/// `MockStatusProvider` that reads this, so flipping `popover` (and applying) updates the real
/// popover live. Flip `useLiveDaemon` to fall back to the actual XPC client.
@MainActor
@Observable
final class DebugControl {
    static let shared = DebugControl()

    var popover: PopoverScenario = .manyAgents
    var useLiveDaemon = false

    /// The live menu-bar model, set by `AdrafinilApp` at launch. Used to force an immediate refresh
    /// when the scenario changes (instead of waiting for the 2s poll) and to render a live preview.
    @ObservationIgnored var statusModel: AppStatusModel?

    /// Set by `AppDelegate` at launch. The control panel is hosted in an AppKit window where
    /// `NSApp.delegate as? AppDelegate` can come back nil, so we hold an explicit reference.
    @ObservationIgnored weak var appDelegate: AppDelegate?

    @ObservationIgnored let liveClient = DaemonClient()

    private init() {}

    /// Re-fetch now so a scenario switch is reflected immediately.
    func apply() { Task { await statusModel?.refresh() } }
}

/// `StatusProviding` backed by `DebugControl`. Serves the selected scenario's snapshot (or throws
/// its error), or delegates to the real daemon when `useLiveDaemon` is on.
@MainActor
final class MockStatusProvider: StatusProviding {
    private let control: DebugControl
    init(_ control: DebugControl = .shared) { self.control = control }

    func fetchStatus() async throws -> DaemonStatus {
        if control.useLiveDaemon { return try await control.liveClient.fetchStatus() }
        if let error = control.popover.error { throw error }
        return control.popover.status
    }

    func forceReleaseAll() async throws {
        if control.useLiveDaemon { try await control.liveClient.forceReleaseAll(); return }
        control.popover = .idle
    }

    func reloadSettings() async throws {
        if control.useLiveDaemon { try await control.liveClient.reloadSettings() }
    }

    func consumeAwaySummary() async -> AwaySummary? {
        control.useLiveDaemon ? await control.liveClient.consumeAwaySummary() : nil
    }
}
#endif
