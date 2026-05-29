import Foundation
import AdrafinilShared

let args = Array(CommandLine.arguments.dropFirst())

guard let first = args.first else {
    CLIUsage.printShortUsage()
    exit(1)
}

let rest = Array(args.dropFirst())

do {
    switch first {
    case "acquire":           try AcquireCommand.run(args: rest)
    case "release":           try ReleaseCommand.run(args: rest)
    case "status":            try StatusCommand.run(args: rest)
    case "install-hooks":     try InstallHooksCommand.run(args: rest)
    case "uninstall-hooks":   try UninstallHooksCommand.run(args: rest)
    case "daemon-status":     try DaemonStatusCommand.run(args: rest)
    case "version", "--version", "-v":
        print("adrafinil 0.1.0")
    case "help", "--help", "-h":
        CLIUsage.printFullUsage()
    default:
        FileHandle.standardError.write(Data("Unknown command: \(first)\n".utf8))
        CLIUsage.printShortUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

enum CLIUsage {
    static func printShortUsage() {
        print("""
        usage: adrafinil <command> [args]
        commands: acquire | release | status | install-hooks | uninstall-hooks | daemon-status | version
        """)
    }
    static func printFullUsage() {
        print("""
        adrafinil — keep your Mac awake only while AI agents are working

        USAGE:
          adrafinil acquire <session-key> --tool <name> [--reason <text>] [--ttl <seconds>]
          adrafinil release <session-key>
          adrafinil status [--json]
          adrafinil install-hooks [--tool <name>] [--dry-run]
          adrafinil uninstall-hooks [--tool <name>] [--dry-run]
          adrafinil daemon-status
          adrafinil version

        The acquire/release commands are reference-counted and idempotent.
        Use from agent hook configs to keep your Mac awake during a session.
        """)
    }
}
