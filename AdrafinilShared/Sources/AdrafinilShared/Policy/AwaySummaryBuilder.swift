import Foundation

/// Assembles the "while you were away" summary when the lid opens after a period that was closed
/// with at least one active assertion. Pure.
///
/// Each agent that was holding an assertion at lid-close is partitioned by whether its tool is
/// still active at lid-open: still-holding tools land in `stillActive`, the rest in `finished`.
/// Returns nil when nothing was held at close (no summary to show).
public struct AwaySummaryBuilder {
    /// One agent that was holding an assertion at the moment the lid closed.
    public struct HeldAgent: Equatable, Sendable {
        public let tool: String
        public let displayName: String
        public let acquiredAt: Date

        public init(tool: String, displayName: String, acquiredAt: Date) {
            self.tool = tool
            self.displayName = displayName
            self.acquiredAt = acquiredAt
        }
    }

    public init() {}

    public func build(
        heldAtClose: [HeldAgent],
        activeTools: Set<String>,
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
            let item = FinishedAgentSummary(
                tool: held.tool,
                displayName: held.displayName,
                duration: openedAt.timeIntervalSince(held.acquiredAt),
            )
            if activeTools.contains(held.tool) {
                stillActive.append(item)
            } else {
                finished.append(item)
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
