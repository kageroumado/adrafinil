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

    private func held(_ tool: String, key: String? = nil, acquiredAgoBeforeClose ago: TimeInterval) -> AwaySummaryBuilder.HeldAgent {
        AwaySummaryBuilder.HeldAgent(
            key: key ?? "\(tool):session",
            tool: tool,
            displayName: tool.capitalized,
            acquiredAt: closed.addingTimeInterval(-ago),
        )
    }

    @Test
    func `nothing held at close → no summary`() {
        let s = builder.build(
            heldAtClose: [],
            activeKeys: [],
            releasedAt: [:],
            closedAt: closed,
            openedAt: opened,
            peakTemperatureCelsius: nil,
            thermalCutout: false,
        )
        #expect(s == nil)
    }

    @Test
    func `sessions still holding at open land in stillActive; the rest in finished`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 100), held("codex", acquiredAgoBeforeClose: 200)],
            activeKeys: ["codex:session"],
            releasedAt: [:],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: 55, thermalCutout: false,
        ))
        #expect(summary.finished.map(\.tool) == ["claude-code"])
        #expect(summary.stillActive.map(\.tool) == ["codex"])
    }

    /// Partitioning is by KEY: a finished session must not be misfiled as still-active just
    /// because a different session of the same tool is running at lid-open.
    @Test
    func `a finished session is not masked by another session of the same tool`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", key: "claude-code:s1", acquiredAgoBeforeClose: 100)],
            activeKeys: ["claude-code:s2"],
            releasedAt: [:],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: nil, thermalCutout: false,
        ))
        #expect(summary.finished.map(\.key) == ["claude-code:s1"])
        #expect(summary.stillActive.isEmpty)
    }

    @Test
    func `two sessions of the same tool keep distinct identities`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [
                held("claude-code", key: "claude-code:s1", acquiredAgoBeforeClose: 100),
                held("claude-code", key: "claude-code:s2", acquiredAgoBeforeClose: 50),
            ],
            activeKeys: [],
            releasedAt: [:],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: nil, thermalCutout: false,
        ))
        #expect(Set(summary.finished.map(\.id)).count == 2, "Identifiable ids must not collide")
    }

    @Test
    func `a finished session's duration runs to its recorded release, not lid-open`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 100)],
            activeKeys: [],
            // Released 120s after the lid closed; the lid stayed shut another 480s.
            releasedAt: ["claude-code:session": closed.addingTimeInterval(120)],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: nil, thermalCutout: false,
        ))
        #expect(summary.finished.first?.duration == 220, "100s before close + 120s after, NOT the 700s to lid-open")
    }

    @Test
    func `without a recorded release the duration falls back to lid-open`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 100)],
            activeKeys: [], releasedAt: [:],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: nil, thermalCutout: false,
        ))
        #expect(summary.finished.first?.duration == 700)
    }

    @Test
    func `peak temperature and thermal-cutout flag pass through`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 0)],
            activeKeys: [], releasedAt: [:],
            closedAt: closed, openedAt: opened, peakTemperatureCelsius: 88.5, thermalCutout: true,
        ))
        #expect(summary.peakTemperatureCelsius == 88.5)
        #expect(summary.thermalCutout)
    }

    @Test
    func `low-battery cutout flag passes through`() throws {
        let summary = try #require(builder.build(
            heldAtClose: [held("claude-code", acquiredAgoBeforeClose: 0)],
            activeKeys: [], releasedAt: [:],
            closedAt: closed, openedAt: opened,
            peakTemperatureCelsius: nil, thermalCutout: false, lowBatteryCutout: true,
        ))
        #expect(summary.lowBatteryCutout)
        #expect(!summary.thermalCutout)
    }
}
