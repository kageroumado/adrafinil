import Foundation

/// Assembles the "while you were away" summary when the lid opens after a period that was closed
/// with at least one active assertion. Pure.
///
/// Each assertion held at lid-close is partitioned by whether its *key* is still active at
/// lid-open (tool-level matching would misfile a finished session as still-active whenever
/// another session of the same tool is running). Finished durations run to the recorded release
/// time, not to lid-open — an agent that finished in ten minutes must not be reported as having
/// run all night. Returns nil when nothing was held at close (no summary to show).
public struct AwaySummaryBuilder {
    /// One assertion that was held at the moment the lid closed.
    public struct HeldAgent: Equatable, Sendable {
        public let key: String
        public let tool: String
        public let displayName: String
        public let acquiredAt: Date

        public init(key: String, tool: String, displayName: String, acquiredAt: Date) {
            self.key = key
            self.tool = tool
            self.displayName = displayName
            self.acquiredAt = acquiredAt
        }
    }

    public init() {}

    /// - Parameters:
    ///   - activeKeys: assertion keys still held at lid-open.
    ///   - releasedAt: release timestamps recorded while the lid was closed, by key.
    public func build(
        heldAtClose: [HeldAgent],
        activeKeys: Set<String>,
        releasedAt: [String: Date],
        closedAt: Date,
        openedAt: Date,
        peakTemperatureCelsius: Double?,
        thermalCutout: Bool,
        lowBatteryCutout: Bool = false,
    ) -> AwaySummary? {
        guard !heldAtClose.isEmpty else { return nil }

        var finished: [FinishedAgentSummary] = []
        var stillActive: [FinishedAgentSummary] = []
        for held in heldAtClose {
            if activeKeys.contains(held.key) {
                stillActive.append(FinishedAgentSummary(
                    key: held.key,
                    tool: held.tool,
                    displayName: held.displayName,
                    duration: openedAt.timeIntervalSince(held.acquiredAt),
                ))
            } else {
                let end = releasedAt[held.key] ?? openedAt
                finished.append(FinishedAgentSummary(
                    key: held.key,
                    tool: held.tool,
                    displayName: held.displayName,
                    duration: end.timeIntervalSince(held.acquiredAt),
                ))
            }
        }

        return AwaySummary(
            closedAt: closedAt,
            openedAt: openedAt,
            finished: finished,
            stillActive: stillActive,
            peakTemperatureCelsius: peakTemperatureCelsius,
            thermalCutout: thermalCutout,
            lowBatteryCutout: lowBatteryCutout,
        )
    }
}
