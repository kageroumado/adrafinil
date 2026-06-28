#if DEBUG
    import AdrafinilShared
    import SwiftUI

    /// Menu-bar popover states the debug control panel can switch between.
    enum PopoverScenario: String, CaseIterable, Identifiable {
        case idle
        case oneAgent
        case manyAgents
        case withHold
        case lidClosedHot
        case thermalCutout
        case lowBatteryCutout
        case daemonError
        case needsApproval
        case notRegistered
        case serviceUnreachable
        case repairing
        case repairFailed

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .idle: "Idle"
            case .oneAgent: "One agent"
            case .manyAgents: "Many agents"
            case .withHold: "Agent hold"
            case .lidClosedHot: "Lid closed (warm)"
            case .thermalCutout: "Thermal cutout"
            case .lowBatteryCutout: "Low-battery cutout"
            case .daemonError: "Daemon unreachable (generic)"
            case .needsApproval: "Service: needs approval"
            case .notRegistered: "Service: not registered"
            case .serviceUnreachable: "Service: unreachable"
            case .repairing: "Service: repairing…"
            case .repairFailed: "Service: repair failed"
            }
        }

        var status: DaemonStatus {
            switch self {
            case .idle: Fixtures.idle
            case .oneAgent: Fixtures.oneAgent
            case .manyAgents: Fixtures.manyAgents
            case .withHold: Fixtures.withHold
            case .lidClosedHot: Fixtures.lidClosedHot
            case .thermalCutout: Fixtures.thermalCutout
            case .lowBatteryCutout: Fixtures.lowBatteryCutout
            default: Fixtures.idle
            }
        }

        /// All the service-problem scenarios throw, so the daemon reads as unreachable and the popover
        /// shows the problem card (the state itself comes from `serviceState`/`repairPhase`).
        var error: (any Error)? {
            switch self {
            case .daemonError, .needsApproval, .notRegistered, .serviceUnreachable, .repairing, .repairFailed:
                Fixtures.DaemonUnreachable()
            default:
                nil
            }
        }

        /// The classified service state the debug panel drives directly. `.daemonError` stays `.ok` so
        /// it exercises the generic "isn't responding" card (an enabled-but-transient outage).
        var serviceState: AppStatusModel.ServiceState {
            switch self {
            case .needsApproval: .needsApproval
            case .notRegistered: .notRegistered
            case .serviceUnreachable, .repairing, .repairFailed: .unreachable
            default: .ok
            }
        }

        var repairPhase: AppStatusModel.RepairPhase {
            switch self {
            case .repairing: .repairing
            case .repairFailed: .failed("re-registration failed")
            default: .idle
            }
        }
    }

    /// "While you were away" panel variants the control panel can trigger.
    enum AwayScenario: String, CaseIterable, Identifiable {
        case clean
        case activeThermal
        case lowBattery

        var id: String {
            rawValue
        }

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
        /// Mirrors the daemon's paused master switch so the live preview can exercise pause/resume.
        var paused = false

        /// The live menu-bar model, set by `AdrafinilApp` at launch. Used to force an immediate refresh
        /// when the scenario changes (instead of waiting for the heartbeat) and to render a live preview.
        @ObservationIgnored var statusModel: AppStatusModel?

        /// Set by `AppDelegate` at launch. The control panel is hosted in an AppKit window where
        /// `NSApp.delegate as? AppDelegate` can come back nil, so we hold an explicit reference.
        @ObservationIgnored weak var appDelegate: AppDelegate?

        @ObservationIgnored let liveClient = DaemonClient()

        private init() {}

        /// Re-fetch now so a scenario switch is reflected immediately. Service-problem scenarios are
        /// driven directly (set `serviceState`/`repairPhase` and let the model's evaluator stand down)
        /// so they render deterministically without the real `SMAppService`/repair path running.
        func apply() {
            let scenario = popover
            Task { @MainActor in
                guard let model = statusModel else { return }
                let driven = scenario.serviceState != .ok || scenario.repairPhase != .idle
                model.debugOwnsServiceState = driven
                if driven {
                    model.serviceState = scenario.serviceState
                    model.repairPhase = scenario.repairPhase
                } else {
                    // Returning to a normal scenario: hand control back and clear any stuck state.
                    model.serviceState = .ok
                    model.repairPhase = .idle
                }
                await model.refresh()
            }
        }
    }

    /// `StatusProviding` backed by `DebugControl`. Serves the selected scenario's snapshot (or throws
    /// its error), or delegates to the real daemon when `useLiveDaemon` is on.
    @MainActor
    final class MockStatusProvider: StatusProviding {
        private let control: DebugControl
        /// GUI-placed holds, kept here so they survive the next `fetchStatus` (which otherwise rebuilds
        /// a fresh fixture each call) — letting the debug panel exercise the full place → countdown →
        /// release flow without a daemon.
        private var extraHolds: [Assertion] = []
        init(_ control: DebugControl = .shared) {
            self.control = control
        }

        func fetchStatus() async throws -> DaemonStatus {
            if control.useLiveDaemon { return try await control.liveClient.fetchStatus() }
            if let error = control.popover.error { throw error }
            var s = control.popover.status
            if control.paused {
                s.paused = true
                s.assertions = []
                s.isBlocking = false
            } else if !extraHolds.isEmpty {
                s.assertions += extraHolds
                s.isBlocking = true
            }
            return s
        }

        func forceReleaseAll() async throws {
            if control.useLiveDaemon { try await control.liveClient.forceReleaseAll(); return }
            extraHolds.removeAll()
            control.popover = .idle
        }

        func releaseAssertion(key: String) async throws {
            if control.useLiveDaemon { try await control.liveClient.releaseAssertion(key: key); return }
            extraHolds.removeAll { $0.key == key }
        }

        func setPaused(_ paused: Bool) async throws {
            if control.useLiveDaemon { try await control.liveClient.setPaused(paused); return }
            if paused { extraHolds.removeAll() } // pausing releases every hold, like the daemon
            control.paused = paused
        }

        func placeHold(reason: String?, ttlSeconds: Double, tool: String?) async throws -> String {
            if control.useLiveDaemon {
                return try await control.liveClient.placeHold(reason: reason, ttlSeconds: ttlSeconds, tool: tool)
            }
            let label = (tool?.isEmpty == false) ? tool! : ManualHold.defaultTool
            let hold = Assertion(
                key: ManualHold.newKey(),
                tool: label,
                reason: reason,
                pid: -1,
                processName: label,
                ttl: ttlSeconds > 0 ? ttlSeconds : nil,
                origin: .manual,
            )
            extraHolds.append(hold)
            return hold.key
        }

        func reloadSettings() async throws {
            if control.useLiveDaemon { try await control.liveClient.reloadSettings() }
        }

        func consumeAwaySummary() async -> AwaySummary? {
            control.useLiveDaemon ? await control.liveClient.consumeAwaySummary() : nil
        }

        /// The debug model drives updates by re-fetching on scenario switch (`DebugControl.apply`) and
        /// the model's heartbeat, not by push — so finish the stream immediately.
        func statusUpdates() -> AsyncStream<DaemonStatus> {
            AsyncStream { $0.finish() }
        }
    }
#endif
