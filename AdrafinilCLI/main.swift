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
    case "hold":              try HoldCommand.run(args: rest)
    case "release":           try ReleaseCommand.run(args: rest)
    case "status":            try StatusCommand.run(args: rest)
    case "install-hooks":     try InstallHooksCommand.run(args: rest)
    case "uninstall-hooks":   try UninstallHooksCommand.run(args: rest)
    case "daemon-status":     try DaemonStatusCommand.run(args: rest)
    case "mcp":               MCPServer.run(args: rest)
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
        commands: acquire | hold | release | status | install-hooks | uninstall-hooks | daemon-status | mcp | version
        """)
    }
    static func printFullUsage() {
        print("""
        adrafinil — keep your Mac awake only while AI agents are working

        USAGE:
          adrafinil hold [--reason <text>] [--for <duration>] [--pid <n>] [--tool <name>]
          adrafinil release <hold-id | session-key>
          adrafinil acquire <session-key> --tool <name> [--reason <text>] [--ttl <seconds>]
          adrafinil status [--json]
          adrafinil install-hooks [--tool <name>] [--dry-run]
          adrafinil uninstall-hooks [--tool <name>] [--dry-run]
          adrafinil daemon-status
          adrafinil mcp
          adrafinil version

        AGENT HOLDS:
          `hold` keeps the Mac awake past the end of your turn — for a background job you
          kicked off — and prints a hold id. The hold ends when you `release <id>`, when the
          --pid you named exits, or when its time runs out (default 1h, capped in settings).

            HOLD=$(adrafinil hold --reason "running migration" --for 30m)
            ./migrate.sh
            adrafinil release "$HOLD"

        `acquire`/`release` are the reference-counted hooks wired into agents at setup.
        `mcp` runs a Model Context Protocol server exposing holds as agent-callable tools.
        """)
    }
}
