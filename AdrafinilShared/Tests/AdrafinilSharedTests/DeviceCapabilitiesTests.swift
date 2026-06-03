import Testing
@testable import AdrafinilShared

@Suite("DeviceCapabilities")
struct DeviceCapabilitiesTests {
    @Test
    func `laptop is not desktop`() {
        #expect(!DeviceCapabilities(hasLid: true, hasBattery: true).isDesktop)
    }

    @Test
    func `both absent is desktop`() {
        #expect(DeviceCapabilities(hasLid: false, hasBattery: false).isDesktop)
    }

    @Test
    func `either signal present is not desktop`() {
        // Defensive: a laptop whose lid probe transiently misses still has a battery, so it must
        // not be mislabeled a desktop (and vice versa).
        #expect(!DeviceCapabilities(hasLid: false, hasBattery: true).isDesktop)
        #expect(!DeviceCapabilities(hasLid: true, hasBattery: false).isDesktop)
    }
}
