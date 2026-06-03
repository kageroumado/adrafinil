import Foundation

extension TimeInterval {
    /// Compact "Xm Ys" / "Ys" rendering of a duration, e.g. `90` → `"1m 30s"`, `42` → `"42s"`.
    var compactDurationString: String {
        let total = Int(self)
        let minutes = total / 60
        let seconds = total % 60
        return minutes == 0 ? "\(seconds)s" : "\(minutes)m \(seconds)s"
    }

    /// Coarse "time left" rendering for a hold countdown: `"1h 5m left"`, `"23m left"`, or
    /// `"<1m left"` once under a minute. Minute granularity — a per-second tick would be noise.
    var remainingString: String {
        let total = max(0, Int(rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m left" : "\(hours)h left" }
        if minutes > 0 { return "\(minutes)m left" }
        return "<1m left"
    }
}
