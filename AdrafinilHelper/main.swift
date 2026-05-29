import Foundation
import AdrafinilShared

let listener = NSXPCListener(machServiceName: AdrafinilConstants.helperMachServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
