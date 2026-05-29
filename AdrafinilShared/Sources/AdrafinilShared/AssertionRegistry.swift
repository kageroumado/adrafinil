import Foundation

/// Reference-counted assertion store. The daemon's source of truth for "is
/// any agent currently active." Idempotent on acquire+release by key.
public actor AssertionRegistry {
    private var assertions: [String: Assertion] = [:]
    private var wasBlocking: Bool = false

    /// Emits the new value of `isBlocking` whenever it flips (false→true or true→false).
    /// A single consumer (the daemon) iterates this to drive the sleep-blocking helper.
    /// The stream is buffered, so a transition emitted before iteration begins is not lost,
    /// and values are delivered in order — the consumer applies them serially, so the helper
    /// is never left in a stale state by out-of-order updates.
    public nonisolated let blockingStateChanges: AsyncStream<Bool>
    private let blockingContinuation: AsyncStream<Bool>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.blockingStateChanges = stream
        self.blockingContinuation = continuation
    }

    public var isBlocking: Bool { !assertions.isEmpty }

    public var count: Int { assertions.count }

    public func snapshot() -> [Assertion] {
        Array(assertions.values).sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// Adds an assertion. Returns `true` if it was newly added, `false` if a duplicate
    /// (same key) — in which case it is a no-op for the count, but the existing
    /// assertion's `lastActivityAt` is refreshed so the idle sweep treats it as active.
    @discardableResult
    public func acquire(_ assertion: Assertion) -> Bool {
        if var existing = assertions[assertion.key] {
            existing.lastActivityAt = Date()
            assertions[assertion.key] = existing
            return false
        }
        assertions[assertion.key] = assertion
        notifyIfNeeded()
        return true
    }

    /// Removes an assertion. Returns `true` if a matching key existed, `false` otherwise
    /// (an unknown-key release is a no-op — the caller may surface a warning, SPEC §5.6).
    @discardableResult
    public func release(key: String) -> Bool {
        guard assertions.removeValue(forKey: key) != nil else { return false }
        notifyIfNeeded()
        return true
    }

    @discardableResult
    public func releaseAll(matchingPid pid: pid_t) -> Int {
        // Assertions with a non-positive PID are sentinels (the CLI could not identify a
        // real agent process). They must never be matched by a process-exit event, or one
        // dead process would drop every PID-less assertion at once.
        guard pid > 0 else { return 0 }
        let matching = assertions.values.filter { $0.pid == pid }.map(\.key)
        for k in matching { assertions.removeValue(forKey: k) }
        notifyIfNeeded()
        return matching.count
    }

    public func removeAll() {
        assertions.removeAll()
        notifyIfNeeded()
    }

    public func replaceAll(with values: [Assertion]) {
        // Last-wins on duplicate keys rather than trapping — a corrupted or hand-edited
        // state.json with repeated keys must not crash the daemon on restore.
        assertions = Dictionary(values.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        notifyIfNeeded()
    }

    public func touch(key: String) {
        guard var a = assertions[key] else { return }
        a.lastActivityAt = Date()
        assertions[key] = a
    }

    private func notifyIfNeeded() {
        let nowBlocking = isBlocking
        if nowBlocking != wasBlocking {
            wasBlocking = nowBlocking
            blockingContinuation.yield(nowBlocking)
        }
    }
}
