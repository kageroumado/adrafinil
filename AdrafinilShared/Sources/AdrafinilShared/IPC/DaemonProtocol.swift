import Foundation

/// XPC interface exposed by AdrafinilDaemon for the menu bar app.
/// Reply closures are `@Sendable`: NSXPC delivers them on its own private queue, so they
/// must not be `@MainActor`-isolated (which under default isolation they otherwise would be,
/// causing a queue-assertion trap when the reply fires off the main actor).
@objc public protocol DaemonXPCProtocol {
    /// Returns the current daemon status as a JSON-encoded `DaemonStatus`.
    func status(reply: @escaping @Sendable (Data?, Error?) -> Void)

    /// Force-releases every assertion.
    func forceReleaseAll(reply: @escaping @Sendable (Bool) -> Void)

    /// Releases a single assertion by its registry key — used by the popover's per-row release
    /// (e.g. cancelling an agent hold). Replies `true` if a matching assertion existed.
    func releaseAssertion(key: String, reply: @escaping @Sendable (Bool) -> Void)

    /// Pauses or resumes the whole app. Pausing releases everything and ignores agent acquires
    /// until resumed. Drives the menu-bar "Let it sleep" / "Resume" toggle.
    func setPaused(_ paused: Bool, reply: @escaping @Sendable (Bool) -> Void)

    /// Reapplies the user's settings (the daemon reloads from disk).
    func reloadSettings(reply: @escaping @Sendable (Bool) -> Void)

    /// Returns the daemon's running version.
    func version(reply: @escaping @Sendable (String) -> Void)

    /// Returns the pending "while you were away" summary as a JSON-encoded `AwaySummary`,
    /// if the lid was just opened after a period that was closed with active assertions,
    /// then clears it (consume-once). Replies with `nil` data when there is nothing pending.
    func consumeAwaySummary(reply: @escaping @Sendable (Data?, Error?) -> Void)
}
