import Testing
@testable import AdrafinilShared

@Suite("LidActionDecider")
struct LidActionDeciderTests {
    private let decider = LidActionDecider()

    @Test
    func `blocking with both settings on chimes locks and tracks`() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: true, soundOnLidClose: true)
        #expect(d.shouldChime)
        #expect(d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test
    func `lock setting off still chimes and tracks but does not lock`() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: false, soundOnLidClose: true)
        #expect(d.shouldChime)
        #expect(!d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test
    func `sound setting off still locks and tracks but does not chime`() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: true, soundOnLidClose: false)
        #expect(!d.shouldChime)
        #expect(d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test
    func `both settings off only tracks`() {
        let d = decider.onLidClose(isBlocking: true, lockOnLidClose: false, soundOnLidClose: false)
        #expect(!d.shouldChime)
        #expect(!d.shouldLock)
        #expect(d.shouldBeginAwayTracking)
    }

    @Test
    func `Not blocking → do nothing, regardless of settings`() {
        for lock in [true, false] {
            for sound in [true, false] {
                let d = decider.onLidClose(isBlocking: false, lockOnLidClose: lock, soundOnLidClose: sound)
                #expect(d == .none)
            }
        }
    }
}
