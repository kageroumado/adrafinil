import Foundation

extension DefaultStringInterpolation {
    /// Emits `item` as a double-quoted JS string literal with proper escaping (JSON string
    /// encoding is a subset of JS), so quotes or backslashes in the bundle path can't break a
    /// generated plugin.
    mutating func appendInterpolation(jsStringLiteral item: String) {
        if let data = try? JSONSerialization.data(withJSONObject: item, options: .fragmentsAllowed),
           let literal = String(data: data, encoding: .utf8) {
            appendInterpolation(literal)
        } else {
            appendInterpolation("\"\(item)\"")
        }
    }
}
