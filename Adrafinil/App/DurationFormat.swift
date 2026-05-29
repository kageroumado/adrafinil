import Foundation

extension TimeInterval {
    /// Compact "Xm Ys" / "Ys" rendering of a duration, e.g. `90` → `"1m 30s"`, `42` → `"42s"`.
    var compactDurationString: String {
        let total = Int(self)
        let minutes = total / 60
        let seconds = total % 60
        return minutes == 0 ? "\(seconds)s" : "\(minutes)m \(seconds)s"
    }
}
