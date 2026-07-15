/// Tracks whether the privileged helper has proved that a renewable lease protects the current
/// sleep block. Failures latch until the helper answers the lease selector successfully; repeated
/// failures cannot degrade into an unleased compatibility mode.
public struct HelperLeaseCapability: Sendable {
    private enum State: Sendable, Equatable {
        case unverified
        case active
        case failed
    }

    private var state: State = .unverified

    public init() {}

    public var allowsBlocking: Bool {
        state == .active
    }
    public var failureLatched: Bool {
        state == .failed
    }

    /// Returns `true` only for the transition into the failed state, so callers can force-release
    /// once without repeatedly invoking the privileged unblock path for the same outage.
    @discardableResult
    public mutating func recordRenewalFailure() -> Bool {
        let newlyFailed = state != .failed
        state = .failed
        return newlyFailed
    }

    public mutating func recordRenewalSuccess(isActive: Bool) {
        state = isActive ? .active : .unverified
    }

    public mutating func recordUnblocked() {
        if state == .active {
            state = .unverified
        }
    }
}
