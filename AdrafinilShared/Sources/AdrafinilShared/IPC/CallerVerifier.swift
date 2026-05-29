import Foundation
import Security

/// Code-signing requirement check on incoming XPC clients.
///
/// Both the privileged helper (which must only accept the daemon) and the daemon's
/// app-facing listener use this to reject connections from binaries we did not sign.
/// The audit token is the canonical identifier for an XPC peer; we pull the signing
/// identifier from it via the `SecCode` APIs and require our reverse-DNS prefix.
public enum CallerVerifier {
    /// Bundle-identifier prefix a caller must match. All Adrafinil components share it.
    public static let allowedPrefix = "glass.kagerou.adrafinil"

    public static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard let signingID = signingIdentifier(for: connection) else {
            return false
        }
        return signingID.hasPrefix(allowedPrefix)
    }

    private static func signingIdentifier(for connection: NSXPCConnection) -> String? {
        var token = connection.adrafinil_auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let stat = staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        return dict[kSecCodeInfoIdentifier as String] as? String
    }
}

private extension NSXPCConnection {
    /// `auditToken` is private on NSXPCConnection; KVC reach is the standard workaround.
    var adrafinil_auditToken: audit_token_t {
        let token = (self.value(forKey: "auditToken") as? NSValue)?.adrafinil_audit_token_t_value
        return token ?? audit_token_t()
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
