import Foundation

/// Locale-aware duration styles for the popover: `1h 30m` in English, `1小时30分钟` in Chinese.
enum DurationFormat {
    /// Hours and minutes in the narrowest form the locale offers; zero-valued units drop out.
    static let narrow = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .narrow)
}

extension TimeInterval {
    /// How long an agent has been working: `1m 30s` / `42s`, past an hour `1h 5m`.
    var elapsedString: String {
        let total = Int(self)
        let units: Set<Duration.UnitsFormatStyle.Unit> = total < 3_600 ? [.minutes, .seconds] : [.hours, .minutes]
        return Duration.seconds(total).formatted(.units(allowed: units, width: .narrow))
    }

    /// Coarse time left on a countdown: `1h 59m`, `23m`, or `<1m` under a minute. Minute
    /// granularity — a per-second tick would be noise.
    var remainingString: String {
        let minutes = Int(self) / 60
        guard minutes > 0 else { return String(localized: "<1m", comment: "Less than one minute left") }
        return Duration.seconds(minutes * 60).formatted(DurationFormat.narrow)
    }
}
