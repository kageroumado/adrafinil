import Foundation
import AdrafinilShared
import ServiceManagement
import OSLog

/// Registers the AdrafinilHelper LaunchDaemon and the AdrafinilDaemon LaunchAgent
/// via SMAppService. First launch triggers the system approval prompt; later launches
/// just verify status.
@MainActor
enum HelperInstaller {
    private static let log = Logger(subsystem: AdrafinilConstants.appBundleID, category: "HelperInstaller")

    static var isFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: "AdrafinilDidCompleteFirstRun")
    }

    static func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: "AdrafinilDidCompleteFirstRun")
    }

    static func installIfNeeded() async {
        let helper = SMAppService.daemon(plistName: "LaunchDaemon.plist")
        let agent = SMAppService.agent(plistName: "LaunchAgent.plist")

        await registerIfNeeded(service: helper, name: "Helper")
        await registerIfNeeded(service: agent, name: "Daemon")

        markFirstRunComplete()
    }

    private static func registerIfNeeded(service: SMAppService, name: String) async {
        switch service.status {
        case .enabled:
            log.info("\(name) already enabled")
        case .notRegistered, .notFound:
            do {
                try service.register()
                log.info("\(name) registered")
            } catch {
                log.error("\(name) registration failed: \(error.localizedDescription)")
            }
        case .requiresApproval:
            log.warning("\(name) requires user approval — opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
        @unknown default:
            log.warning("\(name) in unknown SMAppService state")
        }
    }
}
