#if DEBUG
import Foundation
import AdrafinilShared

/// Canned data for `#Preview`s and the DEBUG gallery, so every view can be exercised across its
/// states without a running daemon.
enum Fixtures {

    static func assertion(_ tool: String, reason: String?, minutesAgo: Double, pid: pid_t = 4242) -> Assertion {
        Assertion(
            key: "\(tool):\(pid)",
            tool: tool,
            reason: reason,
            pid: pid,
            processName: tool,
            acquiredAt: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }

    /// An explicit agent hold: `.manual` origin, TTL-bounded, idle-exempt.
    static func hold(_ tool: String, reason: String?, minutesAgo: Double, ttlMinutes: Double, pid: pid_t = -1) -> Assertion {
        Assertion(
            key: ManualHold.newKey(),
            tool: tool,
            reason: reason,
            pid: pid,
            processName: tool,
            acquiredAt: Date().addingTimeInterval(-minutesAgo * 60),
            ttl: ttlMinutes * 60,
            origin: .manual
        )
    }

    // MARK: - DaemonStatus scenarios

    static var idle: DaemonStatus {
        DaemonStatus(isBlocking: false, assertions: [], lidClosed: false,
                     helperConnected: true, cpuTemperatureCelsius: 44, lastEvent: .released)
    }

    static var oneAgent: DaemonStatus {
        DaemonStatus(
            isBlocking: true,
            assertions: [assertion("claude-code", reason: "Refactoring auth module", minutesAgo: 12)],
            lidClosed: false, helperConnected: true, cpuTemperatureCelsius: 58, lastEvent: .acquired)
    }

    static var manyAgents: DaemonStatus {
        DaemonStatus(
            isBlocking: true,
            assertions: [
                assertion("claude-code", reason: "Refactoring auth module", minutesAgo: 12, pid: 101),
                assertion("cursor", reason: "Running tests", minutesAgo: 4, pid: 102),
                assertion("codex", reason: nil, minutesAgo: 1, pid: 103),
            ],
            lidClosed: true, helperConnected: true, cpuTemperatureCelsius: 71, lastEvent: .acquired)
    }

    /// A live agent plus a deliberate agent hold (exercises the pin glyph, reason, countdown, ✕).
    static var withHold: DaemonStatus {
        DaemonStatus(
            isBlocking: true,
            assertions: [
                assertion("claude-code", reason: nil, minutesAgo: 8, pid: 201),
                hold("claude-code", reason: "running DB migration", minutesAgo: 7, ttlMinutes: 30),
            ],
            lidClosed: false, helperConnected: true, cpuTemperatureCelsius: 63, lastEvent: .acquired)
    }

    static var thermalCutout: DaemonStatus {
        DaemonStatus(isBlocking: false, assertions: [], lidClosed: true,
                     helperConnected: true, cpuTemperatureCelsius: 84,
                     lastEvent: .thermalCutout, lastEventAt: Date())
    }

    static var lowBatteryCutout: DaemonStatus {
        DaemonStatus(isBlocking: false, assertions: [], lidClosed: true,
                     helperConnected: true, cpuTemperatureCelsius: 52,
                     lastEvent: .lowBatteryCutout, lastEventAt: Date())
    }

    static var lidClosedHot: DaemonStatus {
        DaemonStatus(
            isBlocking: true,
            assertions: [assertion("claude-code", reason: "Long build", minutesAgo: 23)],
            lidClosed: true, helperConnected: true, cpuTemperatureCelsius: 79, lastEvent: .lidClosed)
    }

    // MARK: - AwaySummary scenarios

    static var awayClean: AwaySummary {
        AwaySummary(
            closedAt: Date().addingTimeInterval(-600), openedAt: Date(),
            finished: [
                FinishedAgentSummary(tool: "claude-code", displayName: "Claude Code", duration: 252),
                FinishedAgentSummary(tool: "cursor", displayName: "Cursor", duration: 128),
            ],
            stillActive: [], peakTemperatureCelsius: 67, thermalCutout: false)
    }

    static var awayWithActiveAndCutout: AwaySummary {
        AwaySummary(
            closedAt: Date().addingTimeInterval(-1800), openedAt: Date(),
            finished: [FinishedAgentSummary(tool: "codex", displayName: "Codex", duration: 540)],
            stillActive: [FinishedAgentSummary(tool: "claude-code", displayName: "Claude Code", duration: 1700)],
            peakTemperatureCelsius: 86, thermalCutout: true)
    }

    static var awayLowBattery: AwaySummary {
        AwaySummary(
            closedAt: Date().addingTimeInterval(-2400), openedAt: Date(),
            finished: [FinishedAgentSummary(tool: "claude-code", displayName: "Claude Code", duration: 2100)],
            stillActive: [], peakTemperatureCelsius: 61, thermalCutout: false, lowBatteryCutout: true)
    }

    // MARK: - Error provider

    struct DaemonUnreachable: Error, LocalizedError {
        var errorDescription: String? { "Daemon not reachable" }
    }
}
#endif
