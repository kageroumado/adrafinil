import Foundation

/// Decides what the daemon should do the instant the lid closes, given the current blocking
/// state and the user's lid-close preferences.
///
/// Pure and side-effect-free, so the gating can be exhaustively unit-tested without the real
/// screen-lock (`SACLockScreenImmediate`), chime, or IORegistry machinery. The single gate is
/// "are we keeping the Mac awake for an agent?" — with zero assertions a lid close is an ordinary
/// sleep and Adrafinil does nothing. While blocking, the chime and the explicit screen lock are
/// each independently toggleable, but away-tracking always begins so the lid-open summary
/// can be assembled.
public struct LidActionDecider {
    public struct Decision: Equatable, Sendable {
        /// Play the lid-close chime (the screen is off, so it's the only close-time feedback).
        public let shouldChime: Bool
        /// Explicitly lock the screen — works even while an idle-lock-prevention assertion is held.
        public let shouldLock: Bool
        /// Snapshot the held assertions and start tracking for the "while you were away" summary.
        public let shouldBeginAwayTracking: Bool

        public init(shouldChime: Bool, shouldLock: Bool, shouldBeginAwayTracking: Bool) {
            self.shouldChime = shouldChime
            self.shouldLock = shouldLock
            self.shouldBeginAwayTracking = shouldBeginAwayTracking
        }

        /// Do nothing — no agent is active, so the lid close is a normal sleep.
        public static let none = Decision(shouldChime: false, shouldLock: false, shouldBeginAwayTracking: false)
    }

    public init() {}

    /// - Parameters:
    ///   - isBlocking: whether ≥1 assertion is currently held.
    ///   - lockOnLidClose: the `lockOnLidClose` setting.
    ///   - soundOnLidClose: the `soundOnLidClose` setting.
    public func onLidClose(isBlocking: Bool, lockOnLidClose: Bool, soundOnLidClose: Bool) -> Decision {
        guard isBlocking else { return .none }
        return Decision(
            shouldChime: soundOnLidClose,
            shouldLock: lockOnLidClose,
            shouldBeginAwayTracking: true,
        )
    }
}
