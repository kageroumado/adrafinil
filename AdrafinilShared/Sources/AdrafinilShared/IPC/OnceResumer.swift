import Foundation
import os

/// Invokes a closure exactly once, no matter how many times `resume` is called.
///
/// XPC delivers a reply block and the connection's error handler on background queues, and
/// for a failed message it is possible for neither (continuation leak → caller hangs) or, in
/// rare interruption races, both (double-resume → `CheckedContinuation` traps) to fire. Wrap
/// the continuation in an `OnceResumer` so the first outcome wins and the rest are ignored.
///
/// `@unchecked Sendable` is sound here: the only mutable state is guarded by the lock.
public final class OnceResumer<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private let action: (Value) -> Void

    public init(_ action: @escaping (Value) -> Void) {
        self.action = action
    }

    public func resume(_ value: Value) {
        let alreadyResumed: Bool = lock.withLock { done in
            if done { return true }
            done = true
            return false
        }
        guard !alreadyResumed else { return }
        action(value)
    }
}
