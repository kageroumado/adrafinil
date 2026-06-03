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
