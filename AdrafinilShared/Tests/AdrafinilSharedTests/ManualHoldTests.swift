import Testing
import Foundation
@testable import AdrafinilShared

@Suite("ManualHold")
struct ManualHoldTests {
    @Test("clampTTL defaults to one hour when no duration is given")
    func clampDefaults() {
        #expect(ManualHold.clampTTL(nil, capHours: 4) == 3600)
    }

    @Test("clampTTL caps an over-long request")
    func clampCaps() {
        #expect(ManualHold.clampTTL(10 * 3600, capHours: 4) == 4 * 3600)
    }

    @Test("clampTTL passes a within-cap request through")
    func clampPassthrough() {
        #expect(ManualHold.clampTTL(1800, capHours: 4) == 1800)
    }

    @Test("clampTTL floors at one second")
    func clampFloor() {
        #expect(ManualHold.clampTTL(0, capHours: 4) == 1)
        #expect(ManualHold.clampTTL(-50, capHours: 4) == 1)
    }

    @Test("newKey is namespaced and recognized")
    func keyNamespace() {
        let key = ManualHold.newKey()
        #expect(key.hasPrefix("hold:"))
        #expect(ManualHold.isHoldKey(key))
        #expect(!ManualHold.isHoldKey("claude-code:abc123"))
    }

    @Test("newKey is unique across calls")
    func keyUnique() {
        #expect(ManualHold.newKey() != ManualHold.newKey())
    }
}

@Suite("DurationParser")
struct DurationParserTests {
    @Test("bare number is seconds")
    func bareSeconds() {
        #expect(DurationParser.seconds(from: "90") == 90)
    }

    @Test("single units")
    func singleUnits() {
        #expect(DurationParser.seconds(from: "30s") == 30)
        #expect(DurationParser.seconds(from: "45m") == 2700)
        #expect(DurationParser.seconds(from: "2h") == 7200)
        #expect(DurationParser.seconds(from: "1d") == 86400)
    }

    @Test("compound durations sum")
    func compound() {
        #expect(DurationParser.seconds(from: "1h30m") == 5400)
        #expect(DurationParser.seconds(from: "2h15m30s") == 8130)
    }

    @Test("case-insensitive and whitespace-tolerant")
    func tolerant() {
        #expect(DurationParser.seconds(from: " 2H ") == 7200)
    }

    @Test("garbage and ambiguous trailing digits are rejected")
    func rejectsGarbage() {
        #expect(DurationParser.seconds(from: "") == nil)
        #expect(DurationParser.seconds(from: "soon") == nil)
        #expect(DurationParser.seconds(from: "1h30") == nil)
        #expect(DurationParser.seconds(from: "5x") == nil)
    }
}
