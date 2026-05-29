import Foundation
import OSLog
import AdrafinilShared

let bootLog = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Boot")
bootLog.notice("helper \(HelperVersion.string, privacy: .public) starting — uid=\(getuid(), privacy: .public), listening on \(AdrafinilConstants.helperMachServiceName, privacy: .public)")

let listener = NSXPCListener(machServiceName: AdrafinilConstants.helperMachServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
