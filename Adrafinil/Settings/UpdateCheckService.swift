import AdrafinilShared
import Foundation
import Observation
import os

/// Notify-only update check against Adrafinil's public GitHub Releases.
///
/// Adrafinil distributes notarized DMGs through GitHub Releases. Rather than
/// bundle an in-app updater, this performs one lightweight request to GitHub's
/// `releases/latest` endpoint and, when a newer version exists, exposes
/// ``availableVersion`` so the General settings tab can offer a link to the
/// releases page. It never downloads or installs.
@MainActor
@Observable
final class UpdateCheckService {
    /// The newer version (e.g. "1.2") when one is available, else `nil`.
    private(set) var availableVersion: String?

    /// True while a manual check is in flight (drives the button's state).
    private(set) var isChecking = false

    /// Set true after a manual check that found no newer version, so the button can
    /// briefly confirm "You're up to date". Reset when a new check starts.
    private(set) var checkedUpToDate = false

    /// Where the "update available" affordance sends the user.
    let releasesPageURL = URL(string: "https://github.com/kageroumado/adrafinil/releases/latest")!

    @ObservationIgnored private let latestAPI = URL(
        string: "https://api.github.com/repos/kageroumado/adrafinil/releases/latest",
    )!
    @ObservationIgnored private let lastCheckKey = "UpdateCheck.lastCheck"
    @ObservationIgnored private let minInterval: TimeInterval = 60 * 60 * 24 // once/day
    @ObservationIgnored private let log = Logger(
        subsystem: AdrafinilConstants.appBundleID, category: "UpdateCheck",
    )

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? AdrafinilConstants.marketingVersion
    }

    /// Check at most once per `minInterval`. Safe to call on every launch / window open.
    func checkIfDue() async {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date.now.timeIntervalSince(last) < minInterval {
            log.debug("update check: throttled (last check < 24h ago)")
            return
        }
        await check()
    }

    /// Force a check now, ignoring the interval. `manual` drives UI feedback
    /// (spinner / "up to date") so the auto check stays silent.
    func check(manual: Bool = false) async {
        if manual {
            isChecking = true
            checkedUpToDate = false
        }
        defer { if manual { isChecking = false } }

        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            UserDefaults.standard.set(Date.now, forKey: lastCheckKey)

            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            let newer = Self.isNewer(latest, than: currentVersion)
            availableVersion = newer ? latest : nil
            if manual { checkedUpToDate = !newer }
            log.debug("update check: \(release.tagName, privacy: .public) vs \(self.currentVersion, privacy: .public) → \(newer ? "update available" : "up to date", privacy: .public)")
        } catch {
            // Offline, rate-limited, or shape changed — stay quiet and retry later.
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
        /// Force an available-version for the debug control panel (no network).
        func debugSetAvailable(_ version: String?) {
            availableVersion = version
        }
    #endif

    /// Numeric major.minor.patch comparison; missing components are treated as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").compactMap { Int($0) }
        let r = current.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(c.count, r.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Subset of GitHub's release JSON we care about.
private struct GitHubRelease: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
