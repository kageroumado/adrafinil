import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Assertion")
struct AssertionTests {
    @Test
    func `age grows over time`() {
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: Date().addingTimeInterval(-2))
        #expect(a.age >= 2)
    }

    @Test
    func `ttl sets expires at`() throws {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 30)
        #expect(a.expiresAt != nil)
        #expect(try abs(#require(a.expiresAt?.timeIntervalSince(now)) - 30) < 0.01)
    }

    @Test
    func `absent ttl means no expiry`() {
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t")
        #expect(a.expiresAt == nil)
    }

    @Test
    func `identifier is key`() {
        let a = Assertion(key: "claude:abc", tool: "claude", pid: 1, processName: "claude")
        #expect(a.id == "claude:abc")
    }

    @Test
    func `codable roundtrip`() throws {
        let a = Assertion(key: "k", tool: "t", reason: "running", pid: 42, processName: "tool", ttl: 60)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Assertion.self, from: data)
        #expect(decoded == a)
    }

    @Test
    func `zero ttl expires at acquisition`() {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 0)
        #expect(a.expiresAt == now)
    }

    @Test
    func `negative ttl is already expired`() throws {
        let now = Date()
        let a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: -10)
        #expect(a.expiresAt != nil)
        #expect(try #require(a.expiresAt) < now)
    }

    @Test
    func `codable roundtrip preserves activity and expiry`() throws {
        let now = Date()
        var a = Assertion(key: "k", tool: "t", pid: 1, processName: "t", acquiredAt: now, ttl: 60)
        a.lastActivityAt = now.addingTimeInterval(5)
        let decoded = try JSONDecoder().decode(Assertion.self, from: JSONEncoder().encode(a))
        #expect(decoded.lastActivityAt == a.lastActivityAt)
        #expect(decoded.expiresAt == a.expiresAt)
    }

    @Test
    func `away summary roundtrips and computes duration`() throws {
        let closed = Date().addingTimeInterval(-300)
        let opened = Date()
        let summary = AwaySummary(
            closedAt: closed, openedAt: opened,
            finished: [FinishedAgentSummary(key: "claude-code:s1", tool: "claude-code", displayName: "Claude Code", duration: 250)],
            stillActive: [],
            peakTemperatureCelsius: nil,
            thermalCutout: true,
        )
        let decoded = try JSONDecoder().decode(AwaySummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded.finished.count == 1)
        #expect(decoded.finished.first?.displayName == "Claude Code")
        #expect(decoded.stillActive.isEmpty)
        #expect(decoded.thermalCutout == true)
        #expect(decoded.peakTemperatureCelsius == nil)
        #expect(abs(decoded.awayDuration - 300) < 0.01)
    }

    @Test
    func `finished agent summary identifier is its session key`() {
        let f = FinishedAgentSummary(key: "codex:s1", tool: "codex", displayName: "Codex", duration: 10)
        #expect(f.id == "codex:s1")
    }

    @Test
    func `finished agent summary decodes without a key by falling back to tool`() throws {
        let legacy = Data(#"{"tool": "codex", "displayName": "Codex", "duration": 10}"#.utf8)
        let f = try JSONDecoder().decode(FinishedAgentSummary.self, from: legacy)
        #expect(f.key == "codex")
    }

    @Test
    func `daemon status roundtrips with and without optionals`() throws {
        let full = DaemonStatus(
            isBlocking: true,
            assertions: [Assertion(key: "k", tool: "t", pid: 1, processName: "t")],
            lidClosed: true, helperConnected: true,
            cpuTemperatureCelsius: 58.5,
            lastEvent: .thermalCutout, lastEventAt: Date(),
        )
        let d1 = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(full))
        #expect(d1.lastEvent == .thermalCutout)
        #expect(d1.cpuTemperatureCelsius == 58.5)
        #expect(d1.assertions.count == 1)

        let empty = DaemonStatus(
            isBlocking: false, assertions: [], lidClosed: false,
            helperConnected: false, cpuTemperatureCelsius: nil,
            lastEvent: nil, lastEventAt: nil,
        )
        let d2 = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(empty))
        #expect(d2.lastEvent == nil)
        #expect(d2.cpuTemperatureCelsius == nil)
        #expect(d2.lastEventAt == nil)
    }
}
