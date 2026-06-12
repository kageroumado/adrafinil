import AdrafinilShared
import Foundation
import OSLog

let bootLog = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Boot")
bootLog.notice("helper \(HelperVersion.string, privacy: .public) starting — uid=\(getuid(), privacy: .public), listening on \(AdrafinilConstants.helperMachServiceName, privacy: .public)")

let listener = NSXPCListener(machServiceName: AdrafinilConstants.helperMachServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()

// SIGTERM is how launchd ends this process at machine shutdown (and on unregister). The kernel
// reclaims the idle IOPMAssertion with the process, but `disablesleep` is a persistent
// power-management pref that survives the helper AND the reboot — clear it on the way out so a
// Mac shut down mid-block can sleep at the next login window.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    bootLog.notice("SIGTERM — clearing sleep block before exit")
    try? delegate.blocker.set(blocked: false)
    exit(0)
}
termSource.resume()

RunLoop.main.run()
