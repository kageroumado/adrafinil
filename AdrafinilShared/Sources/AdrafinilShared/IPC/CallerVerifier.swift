import Foundation
import Security

/// Code-signing requirement check on incoming XPC clients.
///
/// Both the privileged helper (which must only accept the daemon) and the daemon's
/// app-facing listener use this to reject connections from binaries we did not sign.
/// The audit token is the canonical identifier for an XPC peer; we pull the signing
/// identifier from it via the `SecCode` APIs and require our reverse-DNS prefix.
public enum CallerVerifier {
    /// Reverse-DNS prefix the app bundle signs with. Command-line tool targets (the daemon and
    /// helper) instead sign with their product name as the code identifier — `AdrafinilDaemon` /
    /// `AdrafinilHelper` — because a non-bundle target's identifier defaults to `$(PRODUCT_NAME)`,
    /// not its bundle id. Both shapes are accepted (see `isAdrafinilComponent`).
    public static let allowedPrefix = "glass.kagerou.adrafinil"

    /// Authorize an incoming XPC peer.
    ///
    /// Two conditions, both required (when this process is itself signed with a team):
    /// 1. The caller shares **our own Team Identifier** — read from `self` at runtime, so an
    ///    open-source rebuild under a different Developer ID still authorizes its own components
    ///    without code changes.
    /// 2. The caller is an **Adrafinil component**, not just any app from the same team
    ///    (the developer may ship others — e.g. sibling menu-bar apps — under the same team).
    ///
    /// Only when this process itself has no team (an ad-hoc local dev build) does authorization
    /// fall back to the component-identifier check alone.
    public static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard let caller = signingInfo(for: connection) else { return false }
        return isAuthorizedDecision(
            ownTeam: ownTeamIdentifier(),
            callerTeam: caller.team,
            identifier: caller.identifier,
        )
    }

    /// The pure authorization decision, separated from the Security-framework plumbing so it is
    /// unit-testable. When this process is team-signed, a caller without that exact team is
    /// rejected — including a caller with **no** team at all: an ad-hoc binary can claim any code
    /// identifier it likes (`codesign -s - --identifier …`), so the identifier is only
    /// trustworthy once the team check has anchored the caller to a certificate we control.
    static func isAuthorizedDecision(ownTeam: String?, callerTeam: String?, identifier: String) -> Bool {
        if let ownTeam {
            guard callerTeam == ownTeam else { return false }
        }
        return isAdrafinilComponent(identifier)
    }

    /// Code identifiers of the non-bundle command-line targets (the daemon and helper), which sign
    /// with their `$(PRODUCT_NAME)` rather than a reverse-DNS bundle id. Matched exactly — a prefix
    /// test (`hasPrefix("Adrafinil")`) would also admit a hostile `AdrafinilEvil`, which on an
    /// ad-hoc build (no team to cross-check) is the entire authorization gate.
    static let componentIdentifiers: Set<String> = ["AdrafinilDaemon", "AdrafinilHelper"]

    static func isAdrafinilComponent(_ identifier: String) -> Bool {
        identifier.hasPrefix(allowedPrefix) || componentIdentifiers.contains(identifier)
    }

    private struct SigningInfo {
        let identifier: String
        let team: String?
    }

    private static func signingInfo(for connection: NSXPCConnection) -> SigningInfo? {
        // Fail closed: if the peer's audit token can't be read, we can't identify the caller, so
        // there is no safe way to authorize it. A zeroed token would resolve via
        // `SecCodeCopyGuestWithAttributes` to an unintended guest (pid 0 / self), so it must never
        // be substituted for a missing one.
        guard var token = connection.adrafinil_auditToken else { return nil }
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef,
              let stat = staticCode(for: code) else { return nil }
        return signingInfo(of: stat)
    }

    /// Team Identifier of the *current* process, used as the reference for the caller's team.
    private static func ownTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let code = selfCode,
              let stat = staticCode(for: code) else { return nil }
        return signingInfo(of: stat)?.team
    }

    private static func staticCode(for code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signingInfo(of staticCode: SecStaticCode) -> SigningInfo? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return SigningInfo(identifier: identifier, team: dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

private extension NSXPCConnection {
    /// `auditToken` is private on NSXPCConnection; KVC reach is the standard workaround. Returns nil
    /// when the value can't be read so the caller can fail closed rather than trust a zeroed token.
    var adrafinil_auditToken: audit_token_t? {
        (value(forKey: "auditToken") as? NSValue)?.adrafinil_audit_token_t_value
    }
}

private extension NSValue {
    /// NSValue wraps `audit_token_t` in some macOS releases; if not, return nil and the caller falls back.
    var adrafinil_audit_token_t_value: audit_token_t? {
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        let ok = withUnsafeMutableBytes(of: &token) { ptr -> Bool in
            (self as NSValue).getValue(ptr.baseAddress!, size: size)
            return true
        }
        return ok ? token : nil
    }
}
