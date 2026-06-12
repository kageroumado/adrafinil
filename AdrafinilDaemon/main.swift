import AdrafinilShared
import Foundation
import OSLog

Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "Boot")
    .notice("daemon starting — uid=\(getuid(), privacy: .public), pid=\(getpid(), privacy: .public)")

let daemon = Daemon()

// SIGTERM (launchctl bootout, logout, system shutdown) must clear the helper's sleep block
// before exit: `disablesleep` is a persistent power-management pref that survives this process —
// and the helper, and even a reboot — so an unload while blocked would otherwise leave the Mac
// unable to sleep with nothing left to fix it. The dispatch source delivers the signal on the
// main queue, where the MainActor daemon can run its bounded cleanup.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    Task { @MainActor in
        await daemon.shutdown()
        exit(0)
    }
}
termSource.resume()

Task { @MainActor in
    await daemon.start()
}

RunLoop.main.run()
