import Testing
@testable import AdrafinilShared

/// The full XPC authorization path needs a live signed peer, so it can't be unit-tested here. This
/// covers the identifier allow-list — the part that, on an ad-hoc build with no team to cross-check,
/// is the *entire* gate. A prefix test would have admitted a hostile `AdrafinilEvil`.
@Suite("CallerVerifier identifier allow-list")
struct CallerVerifierTests {
    @Test
    func `the app bundle id and its sub-identifiers are accepted`() {
        #expect(CallerVerifier.isAdrafinilComponent("glass.kagerou.adrafinil"))
        #expect(CallerVerifier.isAdrafinilComponent("glass.kagerou.adrafinil.daemon"))
        #expect(CallerVerifier.isAdrafinilComponent("glass.kagerou.adrafinil.helper"))
    }

    @Test
    func `the non-bundle daemon/helper product names are accepted exactly`() {
        #expect(CallerVerifier.isAdrafinilComponent("AdrafinilDaemon"))
        #expect(CallerVerifier.isAdrafinilComponent("AdrafinilHelper"))
    }

    @Test
    func `a look-alike that merely starts with Adrafinil is rejected`() {
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilEvil"))
        #expect(!CallerVerifier.isAdrafinilComponent("Adrafinil"))
        #expect(!CallerVerifier.isAdrafinilComponent("com.evil.adrafinil"))
        #expect(!CallerVerifier.isAdrafinilComponent(""))
    }
}
