import Foundation
import UserNotifications
import os
import AdrafinilShared

/// Delivers the "while you were away" recap as a native system notification when the lid
/// reopens after a period Adrafinil kept the Mac awake. The system handles presentation,
/// styling, and dismissal — there is no custom panel to manage.
///
/// Foreground presentation (showing a banner while Adrafinil is the active app) requires a
/// `UNUserNotificationCenterDelegate`; `AppDelegate` is that delegate.
@MainActor
final class AwayNotifier {
    static let shared = AwayNotifier()

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "glass.kagerou.adrafinil", category: "notifications")

    private init() {}

    /// Posts a recap notification for `summary`. Requests notification permission the first
    /// time it's needed; if the user has denied it, this logs and does nothing.
    func deliver(_ summary: AwaySummary) {
        log.notice("deliver() called")
        Task {
            guard await ensureAuthorized() else { return }

            let (title, body) = Self.content(for: summary)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil   // the lid-close chime already covers audio; keep the recap quiet

            let request = UNNotificationRequest(
                identifier: "away-\(summary.openedAt.timeIntervalSince1970)",
                content: content,
                trigger: nil   // deliver immediately
            )
            do {
                try await center.add(request)
                log.notice("Delivered away recap: \(title, privacy: .public)")
            } catch {
                log.error("Failed to add notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Asks for permission if undetermined. Returns whether notifications are currently authorized.
    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        log.notice("Authorization status before deliver: \(settings.authorizationStatus.rawValue)")

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.notice("Requested authorization — granted: \(granted)")
                return granted
            } catch {
                log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            log.error("Notifications are denied for Adrafinil in System Settings — recap suppressed")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Copy

    /// Builds a jargon-free title + body for the recap. Safety cutouts take priority in the
    /// headline; the agent tally is always appended as detail.
    static func content(for s: AwaySummary) -> (title: String, body: String) {
        let finished = s.finished.count
        let active = s.stillActive.count

        var detail: [String] = []
        if finished > 0 { detail.append("\(finished) \(finished == 1 ? "agent" : "agents") finished") }
        if active > 0 { detail.append("\(active) still working") }
        let tally = detail.isEmpty ? "No agents were running." : detail.joined(separator: " · ") + "."

        if s.thermalCutout {
            let peak = s.peakTemperatureCelsius.map { " (it peaked at \(Int($0))°C)" } ?? ""
            return ("Your Mac was getting hot", "Adrafinil let it sleep to cool down\(peak). \(tally)")
        }
        if s.lowBatteryCutout {
            return ("Battery was running low", "Adrafinil let your Mac sleep to save power. \(tally)")
        }
        return ("Adrafinil kept your Mac awake", tally)
    }
}
