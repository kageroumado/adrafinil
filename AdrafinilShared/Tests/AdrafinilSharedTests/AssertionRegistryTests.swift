import Foundation
import Testing
@testable import AdrafinilShared

@Suite("AssertionRegistry")
struct AssertionRegistryTests {
    private func make(key: String, pid: pid_t = 100, tool: String = "claude-code") -> Assertion {
        Assertion(key: key, tool: tool, pid: pid, processName: tool)
    }

    @Test
    func `starts empty and not blocking`() async {
        let r = AssertionRegistry()
        #expect(await r.isBlocking == false)
        #expect(await r.snapshot().isEmpty)
    }

    @Test
    func `acquire adds and flips blocking`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        #expect(await r.isBlocking == true)
        #expect(await r.snapshot().count == 1)
    }

    @Test
    func `acquire is idempotent by key`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.acquire(make(key: "a"))
        await r.acquire(make(key: "a"))
        #expect(await r.snapshot().count == 1)
    }

    @Test
    func `release removes assertion`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.release(key: "a")
        #expect(await r.isBlocking == false)
        #expect(await r.snapshot().isEmpty)
    }

    @Test
    func `release unknown key is noop`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.release(key: "does-not-exist")
        #expect(await r.snapshot().count == 1)
    }

    @Test
    func `release does not flip blocking while others held`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.acquire(make(key: "b"))
        await r.release(key: "a")
        #expect(await r.isBlocking == true)
    }

    @Test
    func `release all matching pid removes only matches`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a", pid: 100))
        await r.acquire(make(key: "b", pid: 100))
        await r.acquire(make(key: "c", pid: 200))

        let removed = await r.releaseAll(matchingPid: 100)
        #expect(removed == 2)

        let snap = await r.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.key == "c")
    }

    @Test
    func `remove all clears everything`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.acquire(make(key: "b"))
        await r.removeAll()
        #expect(await r.isBlocking == false)
    }

    @Test
    func `replace all overwrites everything`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.replaceAll(with: [make(key: "x"), make(key: "y")])
        let keys = await r.snapshot().map(\.key)
        #expect(Set(keys) == ["x", "y"])
    }

    @Test
    func `snapshot is sorted by acquired at`() async {
        let r = AssertionRegistry()
        let now = Date()
        let older = Assertion(key: "old", tool: "t", pid: 1, processName: "t", acquiredAt: now.addingTimeInterval(-100))
        let newer = Assertion(key: "new", tool: "t", pid: 2, processName: "t", acquiredAt: now)
        await r.acquire(newer)
        await r.acquire(older)
        let snap = await r.snapshot()
        #expect(snap.map(\.key) == ["old", "new"])
    }

    @Test
    func `blocking state change emits on flip only`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        await r.acquire(make(key: "b")) // already blocking — no emission
        await r.release(key: "a") // still blocking — no emission
        await r.release(key: "b") // now idle — emits false

        var events: [Bool] = []
        for await b in r.blockingStateChanges {
            events.append(b)
            if events.count == 2 { break }
        }
        #expect(events == [true, false])
    }

    @Test
    func `acquire returns true when new false when duplicate`() async {
        let r = AssertionRegistry()
        let first = await r.acquire(make(key: "a"))
        let dup = await r.acquire(make(key: "a"))
        #expect(first == true)
        #expect(dup == false)
    }

    @Test
    func `release reports whether key existed`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a"))
        let hit = await r.release(key: "a")
        let miss = await r.release(key: "a")
        #expect(hit == true)
        #expect(miss == false)
    }

    @Test
    func `touch updates last activity at`() async {
        let r = AssertionRegistry()
        let a = make(key: "a")
        await r.acquire(a)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await r.touch(key: "a")
        let snap = await r.snapshot()
        #expect(snap[0].lastActivityAt > a.lastActivityAt)
    }

    @Test
    func `replace all with duplicate keys does not crash`() async {
        // A corrupted/hand-edited state.json could carry repeated keys; restore must not trap.
        let r = AssertionRegistry()
        let a1 = Assertion(key: "dup", tool: "t", pid: 1, processName: "t")
        let a2 = Assertion(key: "dup", tool: "t", pid: 2, processName: "t")
        await r.replaceAll(with: [a1, a2])
        #expect(await r.snapshot().count == 1)
    }

    @Test
    func `duplicate acquire preserves original acquired at`() async {
        let r = AssertionRegistry()
        let original = Assertion(
            key: "a",
            tool: "t",
            pid: 1,
            processName: "t",
            acquiredAt: Date().addingTimeInterval(-100),
        )
        await r.acquire(original)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await r.acquire(make(key: "a")) // re-acquire with a fresh acquiredAt
        let snap = await r.snapshot()
        #expect(snap.count == 1)
        #expect(snap[0].acquiredAt == original.acquiredAt) // original start time kept
        #expect(snap[0].lastActivityAt > original.acquiredAt) // activity refreshed
    }

    @Test
    func `remove all when empty emits nothing`() async {
        let r = AssertionRegistry()
        await r.removeAll() // empty → must NOT emit
        await r.acquire(make(key: "a")) // emits true
        var first: Bool?
        for await b in r.blockingStateChanges {
            first = b; break
        }
        #expect(first == true) // first emission is the acquire, not a spurious removeAll
    }

    @Test
    func `release all matching nonexistent pid returns zero`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a", pid: 100))
        #expect(await r.releaseAll(matchingPid: 999) == 0)
        #expect(await r.snapshot().count == 1)
    }

    @Test
    func `release all ignores non positive pid`() async {
        // Sentinel (-1) PIDs are PID-less assertions; a process exit must never group them.
        let r = AssertionRegistry()
        await r.acquire(make(key: "a", pid: -1))
        await r.acquire(make(key: "b", pid: -1))
        #expect(await r.releaseAll(matchingPid: -1) == 0)
        #expect(await r.snapshot().count == 2)
    }

    @Test
    func `replace all to empty flips blocking off`() async {
        let r = AssertionRegistry()
        await r.acquire(make(key: "a")) // emits true
        await r.replaceAll(with: []) // flips → emits false
        #expect(await r.isBlocking == false)

        var events: [Bool] = []
        for await b in r.blockingStateChanges {
            events.append(b)
            if events.count == 2 { break }
        }
        #expect(events == [true, false])
    }
}
