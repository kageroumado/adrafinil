import Testing
@testable import AdrafinilShared

/// The CLI socket accepts any same-user caller, so its fields are untrusted input: identity
/// fields get hard caps, display fields get truncated, and daemon-minted key namespaces are
/// rejected so an external acquire can't impersonate a hold or a sniffed assertion.
@Suite("CLIRequestValidator")
struct CLIRequestValidatorTests {
    @Test
    func `a normal hook acquire passes`() {
        #expect(CLIRequestValidator.acquireRejection(key: "claude-code:abc123", tool: "claude-code") == nil)
    }

    @Test
    func `empty and whitespace-only keys are rejected`() {
        #expect(CLIRequestValidator.acquireRejection(key: "", tool: "claude-code") != nil)
        #expect(CLIRequestValidator.acquireRejection(key: "  \n", tool: "claude-code") != nil)
    }

    @Test
    func `oversized key and tool are rejected at the boundary`() {
        let maxKey = String(repeating: "k", count: CLIRequestValidator.maxKeyLength)
        #expect(CLIRequestValidator.acquireRejection(key: maxKey, tool: "t") == nil)
        #expect(CLIRequestValidator.acquireRejection(key: maxKey + "k", tool: "t") != nil)

        let maxTool = String(repeating: "t", count: CLIRequestValidator.maxToolLength)
        #expect(CLIRequestValidator.acquireRejection(key: "k", tool: maxTool) == nil)
        #expect(CLIRequestValidator.acquireRejection(key: "k", tool: maxTool + "t") != nil)
    }

    @Test
    func `reserved key namespaces are rejected`() {
        #expect(CLIRequestValidator.acquireRejection(key: "hold:deadbeef", tool: "evil") != nil)
        #expect(CLIRequestValidator.acquireRejection(key: "sniffed:claude:123", tool: "evil") != nil)
        // A reserved word elsewhere in the key is fine — only the prefix is the namespace.
        #expect(CLIRequestValidator.acquireRejection(key: "claude-code:hold:x", tool: "claude-code") == nil)
    }

    @Test
    func `ttl clamping drops garbage and caps at the backstop`() {
        #expect(CLIRequestValidator.clampedTTL(nil) == nil)
        #expect(CLIRequestValidator.clampedTTL(0) == nil)
        #expect(CLIRequestValidator.clampedTTL(-5) == nil)
        #expect(CLIRequestValidator.clampedTTL(.infinity) == nil, "an infinite TTL would make JSONEncoder throw on persist")
        #expect(CLIRequestValidator.clampedTTL(.nan) == nil)
        #expect(CLIRequestValidator.clampedTTL(600) == 600)
        #expect(CLIRequestValidator.clampedTTL(9e99) == 86_400.0, "finite-but-absurd caps at the 24h backstop")
    }

    @Test
    func `duration parser rejects non-finite spellings`() {
        #expect(DurationParser.seconds(from: "inf") == nil)
        #expect(DurationParser.seconds(from: "nan") == nil)
        #expect(DurationParser.seconds(from: "30m") == 1_800)
    }

    @Test
    func `reasons are truncated not rejected`() {
        #expect(CLIRequestValidator.clampedReason(nil) == nil)
        #expect(CLIRequestValidator.clampedReason("short") == "short")
        let long = String(repeating: "r", count: CLIRequestValidator.maxReasonLength + 100)
        #expect(CLIRequestValidator.clampedReason(long)?.count == CLIRequestValidator.maxReasonLength)
    }
}
