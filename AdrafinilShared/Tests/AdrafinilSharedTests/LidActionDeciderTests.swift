import Testing
@testable import AdrafinilShared

@Suite("LidActionDecider")
struct LidActionDeciderTests {
    private let decider = LidActionDecider()

    @Test func blockingWithBothSettingsOn_chimesLocksAndTracks() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: true, soundOnLidClose: true)
        #expect(d.shouldChime)
        #expect(d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test func lockSettingOff_stillChimesAndTracksButDoesNotLock() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: false, soundOnLidClose: true)
        #expect(d.shouldChime)
        #expect(!d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test func soundSettingOff_stillLocksAndTracksButDoesNotChime() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: true, soundOnLidClose: false)
        #expect(!d.shouldChime)
        #expect(d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test func bothSettingsOff_onlyTracks() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: false, soundOnLidClose: false)
        #expect(!d.shouldChime)
        #expect(!d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test("Not blocking → do nothing, regardless of settings")
    func notBlocking_doesNothing() {
        for lock in [true, false] {
            for sound in [true, false] {
                let d = decider.onLidClose(isBlocking: false, lockOnLidClose: lock, soundOnLidClose: sound)
                #expect(d == .none)
            }
        }
    }
}
