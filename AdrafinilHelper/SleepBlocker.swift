import Foundation

/// Wraps the system call that prevents sleep.
///
/// Shells out to `pmset -a disablesleep <0|1>`, the reliable way to override
/// clamshell sleep — public IOPM assertions do not. It is blunt: `disablesleep`
/// also suppresses idle sleep globally while set, so the helper clears it on
/// release and again on startup (in case a prior instance crashed while it was
/// set). A private IOPM clamshell-override assertion would avoid the global side
/// effect, but isn't verified on current macOS.
final class SleepBlocker {
    private(set) var isBlocked: Bool = false

    init() {
        // On startup, force-clear in case a previous instance crashed while holding the assertion.
        try? setPmsetDisableSleep(false)
    }

    func set(blocked: Bool) throws {
        guard blocked != isBlocked else { return }
        try setPmsetDisableSleep(blocked)
        isBlocked = blocked
    }

    private func setPmsetDisableSleep(_ disable: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "disablesleep", disable ? "1" : "0"]

        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: err, encoding: .utf8) ?? "pmset exited \(task.terminationStatus)"
            throw NSError(domain: "Adrafinil.Helper.SleepBlocker", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
