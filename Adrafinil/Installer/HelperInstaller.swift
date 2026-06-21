import AdrafinilShared
import Foundation
import OSLog
import ServiceManagement

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

    /// Clears the first-run flag so a later relaunch re-runs guided setup. Called by uninstall: once
    /// the services are unregistered and hooks/CLI removed, the app is back to a pristine state, so
    /// relaunching the bundle should walk Setup again rather than come up as a half-configured app.
    static func resetFirstRun() {
        UserDefaults.standard.removeObject(forKey: "AdrafinilDidCompleteFirstRun")
    }

    /// Outcome of a registration attempt, surfaced to the installer UI.
    enum RegistrationResult: Equatable {
        case enabled
        case pendingApproval
        case failed(String)
    }

    /// Outcome of a repair (`repairServices`).
    enum RepairResult: Equatable {
        /// Both services re-registered and enabled — the daemon should come up. The caller still
        /// verifies it actually answers.
        case reregistered
        /// Re-registered, but the user must approve them in Login Items before they enable.
        case needsApproval
        /// Couldn't re-register — the records are wedged beyond what we can clear. The caller should
        /// guide the user to remove Adrafinil in Login Items manually.
        case failed(String)
    }

    /// Tears down our service registrations and registers them fresh, to recover an installation whose
    /// Background Task Management records got into a state launchd won't bring up (e.g. a stale or
    /// duplicated record left by a prior install, seen on first run when the agent never instantiates).
    /// Unregistering drops those records; the subsequent registration recreates them clean. If even
    /// this fails, the records are wedged beyond our reach and the user must remove Adrafinil in Login
    /// Items by hand (a targeted reset, not a system-wide `sfltool resetbtm`).
    static func repairServices() async -> RepairResult {
        log.notice("repair: unregistering services to clear possibly-corrupt records")
        try? await SMAppService.agent(plistName: "LaunchAgent.plist").unregister()
        try? await SMAppService.daemon(plistName: "LaunchDaemon.plist").unregister()
        // The agent's parent is the app login item; re-register it too so the parent record is clean.
        try? await SMAppService.mainApp.unregister()
        try? await Task.sleep(for: .milliseconds(500))

        let results = await installIfNeeded()
        let failures = results.compactMap { entry -> String? in
            if case let .failed(msg) = entry.result { "\(entry.name): \(msg)" } else { nil }
        }
        if !failures.isEmpty {
            log.error("repair: re-registration failed — \(failures.joined(separator: "; "), privacy: .public)")
            return .failed(failures.joined(separator: "; "))
        }
        if results.contains(where: { $0.result == .pendingApproval }) {
            log.notice("repair: re-registered, awaiting user approval")
            return .needsApproval
        }
        log.notice("repair: re-registered and enabled")
        return .reregistered
    }

    @discardableResult
    static func installIfNeeded() async -> [(name: String, result: RegistrationResult)] {
        let helper = SMAppService.daemon(plistName: "LaunchDaemon.plist")
        let agent = SMAppService.agent(plistName: "LaunchAgent.plist")

        let results = await [
            (name: "Helper", result: registerIfNeeded(service: helper, name: "Helper")),
            (name: "Daemon", result: registerIfNeeded(service: agent, name: "Daemon")),
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
        if !results.contains(where: { if case .failed = $0.result { true } else { false } }) {
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
            return await register(service, name: name, allowRemediation: true)
        case .requiresApproval:
            log.notice("\(name, privacy: .public) requires user approval — opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
            return .pendingApproval
        @unknown default:
            log.error("\(name, privacy: .public) in unknown SMAppService state")
            return .failed("unknown SMAppService state")
        }
    }

    /// Registers `service`, recovering once from a collision with a stale Background Task Management
    /// record.
    ///
    /// `register()` can fail with `SMAppServiceErrorDomain` "Operation not permitted" when a prior
    /// install (or a half-completed approval) left a BTM record for the same item that the new
    /// registration collides with rather than replaces — observed on first launch when the agent and
    /// helper never come up. Clearing our own registration with `unregister()` and registering again
    /// replaces that record. This is best-effort and tried exactly once (`allowRemediation`), so a
    /// registration that's genuinely blocked still surfaces as `.failed` to the installer.
    private static func register(_ service: SMAppService, name: String, allowRemediation: Bool) async -> RegistrationResult {
        do {
            try service.register()
            log.notice("\(name, privacy: .public) registered — status now \(statusName(service.status), privacy: .public)")
            return service.status == .enabled ? .enabled : .pendingApproval
        } catch let error as NSError {
            log.error("\(name, privacy: .public) registration FAILED: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
            guard allowRemediation else {
                return .failed("\(error.domain) \(error.code): \(error.localizedDescription)")
            }
            log.notice("\(name, privacy: .public) registration retry: unregistering a possibly-stale record, then re-registering")
            // Capture (don't swallow) an unregister failure: clearing the stale record is the whole
            // point of the retry, so if it fails it's the actionable root cause. Still attempt the
            // re-register — a benign "nothing was registered" shouldn't block a recovery that would
            // otherwise succeed — but if that retry also fails, surface the unregister failure rather
            // than the repeat collision it would otherwise report.
            var unregisterFailure: String?
            do {
                try await service.unregister()
            } catch let unregError as NSError {
                unregisterFailure = "\(unregError.domain) \(unregError.code): \(unregError.localizedDescription)"
                log.error("\(name, privacy: .public) unregister during remediation FAILED: \(unregisterFailure ?? "", privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(300))
            let result = await register(service, name: name, allowRemediation: false)
            if case let .failed(retryMessage) = result, let unregisterFailure {
                return .failed("couldn't clear a stale registration (\(unregisterFailure)); re-registering then failed: \(retryMessage)")
            }
            return result
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
