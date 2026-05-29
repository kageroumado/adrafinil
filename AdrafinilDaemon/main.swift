import Foundation
import AdrafinilShared

Task { @MainActor in
    let daemon = Daemon()
    await daemon.start()
}

RunLoop.main.run()
