import AdrafinilShared
import Darwin
import Foundation
import os
import OSLog

/// Watches arbitrary PIDs for exit using kqueue NOTE_EXIT. When a watched PID exits,
/// invokes `onProcessExit`. Used to release assertions when an agent process dies
/// without firing its end hook (e.g. Codex `Stop`, crashes).
@MainActor
final class ProcessWatcher {
    private let log = Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "ProcessWatcher")

    var onProcessExit: ((pid_t) -> Void)?

    private let core: Core

    init() {
        self.core = Core()
    }

    func start() {
        core.start { [weak self] pid in
            Task { @MainActor in self?.onProcessExit?(pid) }
        }
    }

    func watch(pid: pid_t) {
        core.watch(pid: pid)
    }

    /// Internal nonisolated state — owns the kqueue fd and the watched set.
    private final class Core: @unchecked Sendable {
        private var kq: Int32 = -1
        private var watched: Set<pid_t> = []
        private let mutex = OSAllocatedUnfairLock(initialState: ())
        private var notify: (@Sendable (pid_t) -> Void)?

        func start(notify: @escaping @Sendable (pid_t) -> Void) {
            self.notify = notify
            kq = kqueue()
            guard kq >= 0 else { return }
            Thread { [self] in
                runLoop(notify: notify)
            }.start()
        }

        func watch(pid: pid_t) {
            guard pid > 0, kq >= 0 else { return }
            let shouldAdd: Bool = mutex.withLock { _ in
                if watched.contains(pid) { return false }
                watched.insert(pid)
                return true
            }
            guard shouldAdd else { return }

            var event = kevent(
                ident: UInt(pid),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil,
            )
            let result = kevent(kq, &event, 1, nil, 0, nil)
            if result < 0 {
                // ESRCH: the process exited between the hook firing and this registration —
                // NOTE_EXIT will never come, so treat it as already exited. Leaving the pid in
                // `watched` would also suppress the watch when the pid is later recycled by a
                // new agent.
                mutex.withLock { _ in _ = watched.remove(pid) }
                notify?(pid)
            }
        }

        private func runLoop(notify: @escaping @Sendable (pid_t) -> Void) {
            var event = kevent()
            while kq >= 0 {
                let n = kevent(kq, nil, 0, &event, 1, nil)
                guard n > 0 else { continue }
                if event.filter == Int16(EVFILT_PROC), event.fflags & UInt32(NOTE_EXIT) != 0 {
                    let pid = pid_t(event.ident)
                    mutex.withLock { _ in _ = watched.remove(pid) }
                    notify(pid)
                }
            }
        }
    }
}
