import Foundation

public enum AdrafinilConstants {
    public static let appBundleID = "glass.kagerou.adrafinil"
    public static let daemonBundleID = "glass.kagerou.adrafinil.daemon"
    public static let helperBundleID = "glass.kagerou.adrafinil.helper"

    public static let daemonMachServiceName = "glass.kagerou.adrafinil.daemon"
    public static let helperMachServiceName = "glass.kagerou.adrafinil.helper"

    public static let appSupportDirectoryName = "Adrafinil"
    public static let cliSocketFilename = "cli.sock"
    public static let stateFilename = "state.json"
    public static let configFilename = "config.json"
    public static let eventLogFilename = "events.log"

    /// Version the daemon, helper, and CLI report over their version endpoints. The app bundle reads
    /// its own `CFBundleShortVersionString`; keep this in step with the project's `MARKETING_VERSION`
    /// at release time so every component agrees on a single number.
    public static let marketingVersion = "1.1.1"

    public static let cliBinaryName = "adrafinil"
    public static let cliInstallPath = "/usr/local/bin/adrafinil"
    public static let cliFallbackInstallPath = "\(NSHomeDirectory())/.local/bin/adrafinil"

    public static var appSupportURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cliSocketURL: URL {
        appSupportURL.appendingPathComponent(cliSocketFilename)
    }
}
