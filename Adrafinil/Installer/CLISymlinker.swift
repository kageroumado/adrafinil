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

    /// The CLI path Adrafinil bakes into the hook commands it writes — and the one it compares
    /// against when reporting each agent's connection state. **Deliberately the in-bundle path, not
    /// the `installedCLIPath` symlink**, and that ordering is the whole point:
    ///
    /// `symlinkIfNeeded()` creates `~/.local/bin/adrafinil` (or `/usr/local/bin`) *asynchronously*,
    /// so whether the symlink exists is timing-dependent. Hooks written during first-run setup land
    /// before the symlink does and embed the bundle path; if `installState` later resolved to the
    /// now-present symlink, it would compare two *different absolute paths for the very same binary*
    /// and falsely report every connected agent as "modified externally" — exactly the bug this
    /// fixes. Anchoring both write and inspect to the stable bundle path makes the comparison
    /// deterministic regardless of when the symlink appears. The symlink stays purely a convenience
    /// for a human typing `adrafinil` in a terminal; agents always invoke the real binary in place.
    static var hookCLIPath: String {
        bundledCLIPath ?? installedCLIPath ?? "adrafinil"
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
        // Healthy only when the installed symlink resolves to THIS bundle's CLI. A link left
        // pointing at an old copy of the app (moved, renamed, replaced during an update) still
        // executes — the wrong build — and a dangling one doesn't execute at all; both repair.
        if let installed = installedCLIPath,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: installed)) == source {
            return
        }

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
        // Remove whatever occupies the destination. Checking existence first would skip a
        // DANGLING symlink — `fileExists` follows links and reports false — and the create below
        // would then throw EEXIST forever, leaving the broken link in place.
        try? FileManager.default.removeItem(atPath: dest)
        try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: source)
        log.info("CLI symlinked to \(dest)")
    }
}
