import Foundation

extension TimeInterval {
    /// Compact "Xm Ys" / "Ys" rendering of a duration, e.g. `90` → `"1m 30s"`, `42` → `"42s"`.
    var compactDurationString: String {
        let total = Int(self)
        let minutes = total / 60
        let seconds = total % 60
        return durationFormat(minutes: minutes, seconds: seconds)
    }

    /// Coarse "time left" rendering for a hold countdown: `"1h 5m left"`, `"23m left"`, or
    /// `"<1m left"` once under a minute. Minute granularity — a per-second tick would be noise.
    var remainingString: String {
        let total = max(0, Int(rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return remainingFormat(hours: hours, minutes: minutes)
    }
}

// MARK: - Localized helpers

/// Localized duration display: `"1m 30s"` / `"42s"` (or zh-Hans equivalents).
private func durationFormat(minutes: Int, seconds: Int) -> String {
    if minutes == 0 {
        let fmt = NSLocalizedString(
            "compactDurationSeconds",
            tableName: "Localizable",
            comment: "Duration format: seconds only, e.g. 42s"
        )
        return String(format: fmt, seconds)
    }
    let fmt = NSLocalizedString(
        "compactDuration",
        tableName: "Localizable",
        comment: "Duration format: minutes and seconds, e.g. 1m 30s"
    )
    return String(format: fmt, minutes, seconds)
}

/// Localized remaining-time display: `"1h 5m left"`, `"23m left"`, `"<1m left"`.
private func remainingFormat(hours: Int, minutes: Int) -> String {
    if hours > 0 {
        if minutes > 0 {
            let fmt = NSLocalizedString(
                "remainingHoursMinutes",
                tableName: "Localizable",
                comment: "Remaining time: hours and minutes"
            )
            return String(format: fmt, hours, minutes)
        }
        let fmt = NSLocalizedString(
            "remainingHours",
            tableName: "Localizable",
            comment: "Remaining time: hours only"
        )
        return String(format: fmt, hours)
    }
    if minutes > 0 {
        let fmt = NSLocalizedString(
            "remainingMinutes",
            tableName: "Localizable",
            comment: "Remaining time: minutes only"
        )
        return String(format: fmt, minutes)
    }
    return NSLocalizedString(
        "remainingLessThanMinute",
        tableName: "Localizable",
        comment: "Remaining time: less than a minute"
    )
}
