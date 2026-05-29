import Testing
import Foundation
@testable import AdrafinilShared

@Suite("Assertion")
struct AssertionTests {

    @Test func ageGrowsOverTime() async throws {
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: Date().addingTimeInterval(-2))
        #expect(a.age >= 2)
    }

    @Test func ttlSetsExpiresAt() {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 30)
        #expect(a.expiresAt != nil)
        #expect(abs(a.expiresAt!.timeIntervalSince(now) - 30) < 0.01)
    }

    @Test func absentTtlMeansNoExpiry() {
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t")
        #expect(a.expiresAt == nil)
    }

    @Test func identifierIsKey() {
        let a = Assertion(key: "claude:abc", tool: "claude", pid: 1, processName: "claude")
        #expect(a.id == "claude:abc")
    }

    @Test func codableRoundtrip() throws {
        let a = Assertion(key: "k", tool: "t", reason: "running", pid: 42, processName: "tool", ttl: 60)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Assertion.self, from: data)
        #expect(decoded == a)
    }

    @Test func zeroTtlExpiresAtAcquisition() {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 0)
        #expect(a.expiresAt == now)
    }

    @Test func negativeTtlIsAlreadyExpired() {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: -10)
        #expect(a.expiresAt != nil)
        #expect(a.expiresAt! < now)
    }

    @Test func codableRoundtripPreservesActivityAndExpiry() throws {
        let now = Date()
        var a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 60)
        a.lastActivityAt = now.addingTimeInterval(5)
        let decoded = try JSONDecoder().decode(Assertion.self, from: JSONEncoder().encode(a))
        #expect(decoded.lastActivityAt == a.lastActivityAt)
        #expect(decoded.expiresAt == a.expiresAt)
    }

    @Test func awaySummaryRoundtripsAndComputesDuration() throws {
        let closed = Date().addingTimeInterval(-300)
        let opened = Date()
        let summary = AwaySummary(
            closedAt: closed, openedAt: opened,
            finished: [FinishedAgentSummary(tool: "claude-code", displayName: "Claude Code", duration: 250)],
            stillActive: [],
            peakTemperatureCelsius: nil,
            thermalCutout: true
        )
        let decoded = try JSONDecoder().decode(AwaySummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded.finished.count == 1)
        #expect(decoded.finished.first?.displayName == "Claude Code")
        #expect(decoded.stillActive.isEmpty)
        #expect(decoded.thermalCutout == true)
        #expect(decoded.peakTemperatureCelsius == nil)
        #expect(abs(decoded.awayDuration - 300) < 0.01)
    }

    @Test func finishedAgentSummaryIdentifierIsTool() {
        let f = FinishedAgentSummary(tool: "codex", displayName: "Codex", duration: 10)
        #expect(f.id == "codex")
    }

    @Test func daemonStatusRoundtripsWithAndWithoutOptionals() throws {
        let full = DaemonStatus(
            isBlocking: true,
            assertions: [Assertion(key: "k", tool: "t", pid: 1, processName: "t")],
            lidClosed: true, helperConnected: true,
            cpuTemperatureCelsius: 58.5,
            lastEvent: .thermalCutout, lastEventAt: Date()
        )
        let d1 = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(full))
        #expect(d1.lastEvent == .thermalCutout)
        #expect(d1.cpuTemperatureCelsius == 58.5)
        #expect(d1.assertions.count == 1)

        let empty = DaemonStatus(
            isBlocking: false, assertions: [], lidClosed: false,
            helperConnected: false, cpuTemperatureCelsius: nil,
            lastEvent: nil, lastEventAt: nil
        )
        let d2 = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(empty))
        #expect(d2.lastEvent == nil)
        #expect(d2.cpuTemperatureCelsius == nil)
        #expect(d2.lastEventAt == nil)
    }
}
