import Foundation
import Testing
@testable import AdrafinilShared

@Suite("AwaySummaryBuilder")
struct AwaySummaryBuilderTests {
    private let builder = AwaySummaryBuilder()
    private let closed = Date(timeIntervalSince1970: 1_000_000)
    private var opened: Date {
        closed.addingTimeInterval(600)
    }

    private func held(_ tool: String, acquiredAgoBeforeClose ago: TimeInterval) -> AwaySummaryBuilder.HeldAgent {
        AwaySummaryBuilder.HeldAgent(tool: tool, displayName: tool.capitalized, acquiredAt: closed.addingTimeInterval(-ago))
    }

    @Test
    func `nothing held at close → no summary`() {
        let s = builder.build(
            heldAtClose: [],
            activeTools: [],
            closedAt: closed,
            openedAt: opened,
            peakTemperatureCelsius: nil,
            thermalCutout: false,
        )
        #expect(s == nil)
    }

    @Test
    func `agents still holding at open land in stillActive; the rest in finished`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 100), held("codex", acquiredAgoBeforeClose: 200)],
            activeTools: ["codex"],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: 55, thermalCutout: false,
        ))
        #expect(summary.finished.map(\.tool) == ["claude-code"])
        #expect(summary.stillActive.map(\.tool) == ["codex"])
    }

    @Test
    func `duration spans from acquire time through lid-open`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 100)],
            activeTools: [], closedAt: closed, openedAt: opened, peakTemperatureCelsius: nil, thermalCutout: false,
        ))
        // Acquired 100s before close; opened 600s after close → 700s total.
        #expect(summary.finished.first?.duration == 700)
    }

    @Test
    func `peak temperature and thermal-cutout flag pass through`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 0)],
            activeTools: [], closedAt: closed, openedAt: opened, peakTemperatureCelsius: 88.5, thermalCutout: true,
        ))
        #expect(summary.peakTemperatureCelsius == 88.5)
        #expect(summary.thermalCutout)
    }

    @Test
    func `low-battery cutout flag passes through`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 0)],
            activeTools: [], closedAt: closed, openedAt: opened,
            peakTemperatureCelsius: nil, thermalCutout: false, lowBatteryCutout: true,
        ))
        #expect(summary.lowBatteryCutout)
        #expect(!summary.thermalCutout)
    }
}
