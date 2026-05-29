import Foundation
import OSLog
import AdrafinilShared

Logger(subsystem: AdrafinilConstants.daemonBundleID, category: "Boot")
    .notice("daemon starting — uid=\(getuid(), privacy: .public), pid=\(getpid(), privacy: .public)")

Task { @MainActor in
    let daemon = Daemon()
    await daemon.start()
}

RunLoop.main.run()
