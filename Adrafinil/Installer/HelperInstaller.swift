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

    /// Outcome of a registration attempt, surfaced to the installer UI.
    enum RegistrationResult: Equatable {
        case enabled
        case pendingApproval
        case failed(String)
    }

    @discardableResult
    static func installIfNeeded() async -> [(name: String, result: RegistrationResult)] {
        let helper = SMAppService.daemon(plistName: "LaunchDaemon.plist")
        let agent = SMAppService.agent(plistName: "LaunchAgent.plist")

        let results = [
            (name: "Helper", result: await registerIfNeeded(service: helper, name: "Helper")),
            (name: "Daemon", result: await registerIfNeeded(service: agent, name: "Daemon")),
        ]

        // Register the menu-bar app itself as a login item so it's present after a reboot without
        // any manual step. `launchAtLogin` defaults to true, but its Settings toggle only registers
        // on *change* — so nothing ever enabled it on a fresh install. Setup is where we make it
        // real. (Users can still turn it off later in Settings, which unregisters it.)
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
                log.notice("main app registered as login item")
            }
        } catch {
            log.error("main app login-item registration failed: \(error.localizedDescription, privacy: .public)")
        }

        // Only consider first-run "done" if nothing hard-failed; a pending approval still
        // counts (the services are registered and enable once the user approves). A hard
        // failure leaves the flag clear so the setup flow re-presents on next launch.
        if !results.contains(where: { if case .failed = $0.result { return true } else { return false } }) {
            markFirstRunComplete()
        }
        return results
    }

    private static func registerIfNeeded(service: SMAppService, name: String) async -> RegistrationResult {
        switch service.status {
        case .enabled:
            log.notice("\(name, privacy: .public) already enabled")
            return .enabled
        case .notRegistered, .notFound:
            do {
                try service.register()
                log.notice("\(name, privacy: .public) registered — status now \(statusName(service.status), privacy: .public)")
                return service.status == .enabled ? .enabled : .pendingApproval
            } catch let error as NSError {
                log.error("\(name, privacy: .public) registration FAILED: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
                return .failed("\(error.domain) \(error.code): \(error.localizedDescription)")
            }
        case .requiresApproval:
            log.notice("\(name, privacy: .public) requires user approval — opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
            return .pendingApproval
        @unknown default:
            log.error("\(name, privacy: .public) in unknown SMAppService state")
            return .failed("unknown SMAppService state")
        }
    }

    private static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
}
