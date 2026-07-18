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

    @Test
    func `a linker ad-hoc identifier (build that skipped codesign) is rejected`() {
        // `xcodebuild … CODE_SIGNING_ALLOWED=NO` skips the codesign step entirely, so the linker's
        // fallback ad-hoc signature stamps tools as `<name>-<hex>` instead of the product name.
        // Such a build must not authorize — and won't function: install a build that went through
        // codesign (identifier = product name), e.g. `CODE_SIGN_IDENTITY=-` for local dev.
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilDaemon-55554944572a111aa4e631978f328488fa7c4992"))
    }
}

/// The team check must fail closed: an ad-hoc binary can claim ANY code identifier
/// (`codesign -s - --identifier glass.kagerou.adrafinil.helper`), so when we are team-signed,
/// a caller that presents no team — or the wrong one — must be rejected no matter what
/// identifier it claims.
@Suite("CallerVerifier authorization decision")
struct CallerVerifierDecisionTests {
    private let team = "52K336H235"

    @Test
    func `team-signed self rejects a caller with no team even with a valid identifier`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: nil, identifier: "glass.kagerou.adrafinil.helper",
        ))
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: nil, identifier: "AdrafinilDaemon",
        ))
    }

    @Test
    func `team-signed self rejects a caller from a different team`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: "EVILTEAM00", identifier: "glass.kagerou.adrafinil",
        ))
    }

    @Test
    func `matching team plus component identifier is accepted`() {
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "glass.kagerou.adrafinil",
        ))
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "AdrafinilDaemon",
        ))
    }

    @Test
    func `matching team with a foreign identifier is rejected`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "com.example.other",
        ))
    }

    @Test
    func `ad-hoc self falls back to the identifier allow-list alone`() {
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: nil, identifier: "AdrafinilHelper",
        ))
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: nil, identifier: "AdrafinilEvil",
        ))
        // A team-signed caller hitting an ad-hoc build is still held to the identifier list.
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: team, identifier: "glass.kagerou.adrafinil.daemon",
        ))
    }
}
