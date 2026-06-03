import AdrafinilShared
import Foundation
import OSLog

/// Symlinks the bundled `adrafinil` CLI to /usr/local/bin/adrafinil (or ~/.local/bin
/// on a non-admin install) so hook configs can invoke it as plain `adrafinil`.
@MainActor
enum CLISymlinker {
    private static let log = Logger(subsystem: AdrafinilConstants.appBundleID, category: "CLISymlinker")

    static var installedCLIPath: String? {
        let primary = AdrafinilConstants.cliInstallPath
        let fallback = AdrafinilConstants.cliFallbackInstallPath
        if FileManager.default.isExecutableFile(atPath: primary) { return primary }
        if FileManager.default.isExecutableFile(atPath: fallback) { return fallback }
        return nil
    }

    /// The CLI binary inside the app bundle. It ships in `Contents/Helpers` — *not*
    /// `Contents/MacOS`, where a file named `adrafinil` collides case-insensitively with the
    /// app's own executable `Adrafinil` and shadows it (launching the app would run the CLI and
    /// immediately exit). Older layouts are kept as fallbacks.
    static var bundledCLIPath: String? {
        let base = Bundle.main.bundlePath
        let candidates = [
            "\(base)/Contents/Helpers/adrafinil",
            "\(base)/Contents/MacOS/adrafinil",
            "\(base)/Contents/MacOS/AdrafinilCLI",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func symlinkIfNeeded() async {
        guard let source = bundledCLIPath else {
            log.warning("CLI not found in app bundle")
            return
        }
        if installedCLIPath != nil { return }

        let primary = AdrafinilConstants.cliInstallPath
        if (try? symlink(from: source, to: primary)) != nil { return }

        let fallback = AdrafinilConstants.cliFallbackInstallPath
        try? FileManager.default.createDirectory(
            atPath: (fallback as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        try? symlink(from: source, to: fallback)
    }

    private static func symlink(from source: String, to dest: String) throws {
        // Remove an existing symlink/file if it points to a stale location.
        if FileManager.default.fileExists(atPath: dest) {
            try? FileManager.default.removeItem(atPath: dest)
        }
        try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: source)
        log.info("CLI symlinked to \(dest)")
    }
}
