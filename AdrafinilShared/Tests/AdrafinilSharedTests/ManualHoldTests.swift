import Foundation
import Testing
@testable import AdrafinilShared

@Suite("ManualHold")
struct ManualHoldTests {
    @Test
    func `clampTTL defaults to one hour when no duration is given`() {
        #expect(ManualHold.clampTTL(nil, capHours: 4) == 3_600)
    }

    @Test
    func `clampTTL caps an over-long request`() {
        #expect(ManualHold.clampTTL(10 * 3_600, capHours: 4) == 4 * 3_600)
    }

    @Test
    func `clampTTL passes a within-cap request through`() {
        #expect(ManualHold.clampTTL(1_800, capHours: 4) == 1_800)
    }

    @Test
    func `clampTTL floors at one second`() {
        #expect(ManualHold.clampTTL(0, capHours: 4) == 1)
        #expect(ManualHold.clampTTL(-50, capHours: 4) == 1)
    }

    @Test
    func `newKey is namespaced and recognized`() {
        let key = ManualHold.newKey()
        #expect(key.hasPrefix("hold:"))
        #expect(ManualHold.isHoldKey(key))
        #expect(!ManualHold.isHoldKey("claude-code:abc123"))
    }

    @Test
    func `newKey is unique across calls`() {
        #expect(ManualHold.newKey() != ManualHold.newKey())
    }

    // MARK: - clampExpiry (daemon-side TTL ceiling for hook acquires)

    @Test
    func `clampExpiry leaves a TTL-less assertion untouched`() {
        // Per-turn and sub-agent hooks carry no TTL; they stay governed by the idle policy, not a
        // deadline.
        #expect(ManualHold.clampExpiry(nil, acquiredAt: Date(), capHours: 4) == nil)
    }

    @Test
    func `clampExpiry caps an over-long expiry to the max-hold`() {
        // The background-shell hook requests the 24h ceiling; the daemon must bring it down to the
        // user's live cap so a background task can't pin the Mac past it.
        let acquired = Date(timeIntervalSince1970: 1_000_000)
        let requested = acquired.addingTimeInterval(24 * 3_600)
        let clamped = ManualHold.clampExpiry(requested, acquiredAt: acquired, capHours: 4)
        #expect(clamped == acquired.addingTimeInterval(4 * 3_600))
    }

    @Test
    func `clampExpiry passes a within-cap expiry through`() {
        let acquired = Date(timeIntervalSince1970: 1_000_000)
        let requested = acquired.addingTimeInterval(30 * 60)
        #expect(ManualHold.clampExpiry(requested, acquiredAt: acquired, capHours: 4) == requested)
    }

    @Test
    func `clampExpiry keeps a positive floor for a zero-hour cap`() {
        // A degenerate cap must still yield a future expiry (max(1, …)), never acquiredAt or earlier.
        let acquired = Date(timeIntervalSince1970: 1_000_000)
        let requested = acquired.addingTimeInterval(10 * 3_600)
        let clamped = ManualHold.clampExpiry(requested, acquiredAt: acquired, capHours: 0)
        #expect(clamped == acquired.addingTimeInterval(1))
    }
}

@Suite("DurationParser")
struct DurationParserTests {
    @Test
    func `bare number is seconds`() {
        #expect(DurationParser.seconds(from: "90") == 90)
    }

    @Test
    func `single units`() {
        #expect(DurationParser.seconds(from: "30s") == 30)
        #expect(DurationParser.seconds(from: "45m") == 2_700)
        #expect(DurationParser.seconds(from: "2h") == 7_200)
        #expect(DurationParser.seconds(from: "1d") == 86_400)
    }

    @Test
    func `compound durations sum`() {
        #expect(DurationParser.seconds(from: "1h30m") == 5_400)
        #expect(DurationParser.seconds(from: "2h15m30s") == 8_130)
    }

    @Test
    func `case-insensitive and whitespace-tolerant`() {
        #expect(DurationParser.seconds(from: " 2H ") == 7_200)
    }

    @Test
    func `garbage and ambiguous trailing digits are rejected`() {
        #expect(DurationParser.seconds(from: "") == nil)
        #expect(DurationParser.seconds(from: "soon") == nil)
        #expect(DurationParser.seconds(from: "1h30") == nil)
        #expect(DurationParser.seconds(from: "5x") == nil)
    }
}
