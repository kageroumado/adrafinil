import Foundation

/// Minimal positional / option / flag parser. No dependencies.
///
/// Conventions:
///   - Positionals: any argument not starting with `--`.
///   - Options: `--name value` or `--name=value`.
///   - Flags: `--name` with no following value (or followed by another `--`).
public struct ArgParser {
    public let positionals: [String]
    public let options: [String: String]
    public let flags: Set<String>

    public init(args: [String]) {
        var pos: [String] = []
        var opts: [String: String] = [:]
        var flgs: Set<String> = []

        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if let eq = a.firstIndex(of: "=") {
                    let key = String(a[..<eq])
                    let value = String(a[a.index(after: eq)...])
                    opts[key] = value
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    opts[a] = args[i + 1]
                    i += 1
                } else {
                    flgs.insert(a)
                }
            } else {
                pos.append(a)
            }
            i += 1
        }

        self.positionals = pos
        self.options = opts
        self.flags = flgs
    }

    public func positional(_ index: Int) -> String? {
        positionals.indices.contains(index) ? positionals[index] : nil
    }

    public func option(_ name: String) -> String? { options[name] }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
}
