import Foundation

/// What the daemon persists across restarts: the live assertions plus the user-facing paused
/// bit. Persisting `paused` keeps "Adrafinil is off" true across a daemon relaunch or reboot —
/// the user quit the app expecting their Mac to sleep normally, and a fresh daemon coming up
/// unpaused would let agent hooks re-pin it with no menu bar icon showing why.
public struct PersistedDaemonState: Codable, Sendable {
    public var assertions: [Assertion]
    public var paused: Bool

    public init(assertions: [Assertion], paused: Bool) {
        self.assertions = assertions
        self.paused = paused
    }

    /// Decodes the envelope, falling back to the bare `[Assertion]` array older builds wrote.
    public static func decode(from data: Data) -> PersistedDaemonState? {
        if let state = try? JSONDecoder().decode(PersistedDaemonState.self, from: data) {
            return state
        }
        if let assertions = try? JSONDecoder().decode([Assertion].self, from: data) {
            return PersistedDaemonState(assertions: assertions, paused: false)
        }
        return nil
    }
}
