import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Helper lease capability")
struct HelperLeaseCapabilityTests {
    @Test
    func `renewal failure immediately fails closed and stays latched`() {
        var capability = HelperLeaseCapability()

        let firstFailure = capability.recordRenewalFailure()
        #expect(firstFailure)
        #expect(!capability.allowsBlocking)
        #expect(capability.failureLatched)

        let repeatedFailure = capability.recordRenewalFailure()
        #expect(!repeatedFailure)
        #expect(!capability.allowsBlocking)
        #expect(capability.failureLatched)
    }

    @Test
    func `only an active successful renewal allows blocking`() {
        var capability = HelperLeaseCapability()

        capability.recordRenewalSuccess(isActive: false)
        #expect(!capability.allowsBlocking)

        capability.recordRenewalSuccess(isActive: true)
        #expect(capability.allowsBlocking)
        #expect(!capability.failureLatched)
    }

    @Test
    func `successful capability probe clears a latched failure without claiming an active block`() {
        var capability = HelperLeaseCapability()
        capability.recordRenewalFailure()

        capability.recordRenewalSuccess(isActive: false)

        #expect(!capability.failureLatched)
        #expect(!capability.allowsBlocking)
    }

    @Test
    func `unblocking preserves failure until capability recovery`() {
        var capability = HelperLeaseCapability()
        capability.recordRenewalFailure()

        capability.recordUnblocked()

        #expect(capability.failureLatched)
        #expect(!capability.allowsBlocking)
    }
}
