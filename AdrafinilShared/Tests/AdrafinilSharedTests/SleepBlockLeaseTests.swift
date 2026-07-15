import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Sleep block lease")
struct SleepBlockLeaseTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func `starts inactive`() {
        var lease = SleepBlockLease()

        #expect(lease.expiresAt == nil)
        let expired = lease.expireIfNeeded(now: now)
        #expect(!expired)
    }

    @Test
    func `renew sets deadline from now`() {
        var lease = SleepBlockLease()

        lease.renew(now: now, duration: 15)

        #expect(lease.expiresAt == now.addingTimeInterval(15))
    }

    @Test
    func `renew extends but never shortens deadline`() {
        var lease = SleepBlockLease()
        lease.renew(now: now, duration: 15)

        lease.renew(now: now.addingTimeInterval(5), duration: 15)
        #expect(lease.expiresAt == now.addingTimeInterval(20))

        lease.renew(now: now, duration: 5)
        #expect(lease.expiresAt == now.addingTimeInterval(20))
    }

    @Test
    func `clear removes deadline`() {
        var lease = SleepBlockLease()
        lease.renew(now: now, duration: 15)

        lease.clear()

        #expect(lease.expiresAt == nil)
    }

    @Test
    func `expires at or after deadline but not before`() {
        var lease = SleepBlockLease()
        lease.renew(now: now, duration: 15)

        let expiredBeforeDeadline = lease.expireIfNeeded(now: now.addingTimeInterval(14.999))
        #expect(!expiredBeforeDeadline)
        #expect(lease.expiresAt != nil)
        let expiredAtDeadline = lease.expireIfNeeded(now: now.addingTimeInterval(15))
        #expect(expiredAtDeadline)
        #expect(lease.expiresAt == nil)

        lease.renew(now: now, duration: 15)
        let expiredAfterDeadline = lease.expireIfNeeded(now: now.addingTimeInterval(16))
        #expect(expiredAfterDeadline)
        #expect(lease.expiresAt == nil)
    }
}
