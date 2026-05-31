import Foundation

public struct Assertion: Codable, Sendable, Hashable, Identifiable {
    public let key: String
    public let tool: String
    public let reason: String?
    public let pid: pid_t
    public let processName: String
    public let acquiredAt: Date
    public var lastActivityAt: Date
    public var expiresAt: Date?

    public var id: String { key }

    public var age: TimeInterval { Date().timeIntervalSince(acquiredAt) }

    public init(
        key: String,
        tool: String,
        reason: String? = nil,
        pid: pid_t,
        processName: String,
        acquiredAt: Date = Date(),
        ttl: TimeInterval? = nil
    ) {
        self.key = key
        self.tool = tool
        self.reason = reason
        self.pid = pid
        self.processName = processName
        self.acquiredAt = acquiredAt
        self.lastActivityAt = acquiredAt
        self.expiresAt = ttl.map { acquiredAt.addingTimeInterval($0) }
    }
}

public struct DaemonStatus: Codable, Sendable {
    public var isBlocking: Bool
    public var assertions: [Assertion]
    public var lidClosed: Bool
    public var helperConnected: Bool
    public var cpuTemperatureCelsius: Double?
    public var lastEvent: DaemonEvent?
    /// When `lastEvent` was recorded. Lets the UI scope transient states (e.g. the
    /// 30-second thermal-cutout menu-bar icon) without its own bookkeeping.
    public var lastEventAt: Date?
    /// `true` when the user has paused Adrafinil: all holds are released and agent acquires are
    /// ignored until resumed. The Mac sleeps normally meanwhile.
    public var paused: Bool

    public init(
        isBlocking: Bool,
        assertions: [Assertion],
        lidClosed: Bool,
        helperConnected: Bool,
        cpuTemperatureCelsius: Double?,
        lastEvent: DaemonEvent?,
        lastEventAt: Date? = nil,
        paused: Bool = false
    ) {
        self.isBlocking = isBlocking
        self.assertions = assertions
        self.lidClosed = lidClosed
        self.helperConnected = helperConnected
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.paused = paused
    }
}

/// One agent's line in the "while you were away" summary.
public struct FinishedAgentSummary: Codable, Sendable, Identifiable, Hashable {
    public let tool: String
    public let displayName: String
    public let duration: TimeInterval

    public var id: String { tool }

    public init(tool: String, displayName: String, duration: TimeInterval) {
        self.tool = tool
        self.displayName = displayName
        self.duration = duration
    }
}

/// "While you were away" summary, assembled by the daemon when the lid opens after a
/// period that was closed with at least one active assertion.
public struct AwaySummary: Codable, Sendable {
    public let closedAt: Date
    public let openedAt: Date
    /// Agents that were active at lid-close and finished while closed.
    public let finished: [FinishedAgentSummary]
    /// Agents still holding an assertion at lid-open.
    public let stillActive: [FinishedAgentSummary]
    public let peakTemperatureCelsius: Double?
    public let thermalCutout: Bool
    /// Whether the low-battery cutout fired while the lid was closed.
    public let lowBatteryCutout: Bool

    public var awayDuration: TimeInterval { openedAt.timeIntervalSince(closedAt) }

    public init(
        closedAt: Date,
        openedAt: Date,
        finished: [FinishedAgentSummary],
        stillActive: [FinishedAgentSummary],
        peakTemperatureCelsius: Double?,
        thermalCutout: Bool,
        lowBatteryCutout: Bool = false
    ) {
        self.closedAt = closedAt
        self.openedAt = openedAt
        self.finished = finished
        self.stillActive = stillActive
        self.peakTemperatureCelsius = peakTemperatureCelsius
        self.thermalCutout = thermalCutout
        self.lowBatteryCutout = lowBatteryCutout
    }
}

public enum DaemonEvent: String, Codable, Sendable {
    case acquired
    case released
    case thermalCutout
    case lowBatteryCutout
    case idleRelease
    case lidClosed
    case lidOpened
    case helperLost
    case helperReconnected
}
