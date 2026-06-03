import AdrafinilShared
import Foundation

enum InstallHooksCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let targetTool = parser.option("--tool").flatMap { AgentKind(rawValue: $0) }
        let dryRun = parser.flag("--dry-run")

        let installer = HookInstaller(cliPath: ProcessInfo.processInfo.arguments[0])
        let agents = targetTool.map { [$0] } ?? AgentKind.allCases

        for agent in agents {
            do {
                let result = try installer.install(for: agent, dryRun: dryRun)
                if dryRun {
                    print("[\(agent.displayName)] would write:\n\(result.diff)")
                } else {
                    print("[\(agent.displayName)] \(result.summary)")
                }
            } catch HookInstaller.SkipReason.notInstalled {
                print("[\(agent.displayName)] not detected, skipping")
            } catch let HookInstaller.SkipReason.unsupportedHere(why) {
                print("[\(agent.displayName)] \(why)")
            } catch {
                FileHandle.standardError.write(Data("[\(agent.displayName)] error: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}

enum UninstallHooksCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let targetTool = parser.option("--tool").flatMap { AgentKind(rawValue: $0) }
        let dryRun = parser.flag("--dry-run")
        let installer = HookInstaller(cliPath: ProcessInfo.processInfo.arguments[0])
        let agents = targetTool.map { [$0] } ?? AgentKind.allCases
        for agent in agents {
            do {
                let result = try installer.uninstall(for: agent, dryRun: dryRun)
                if dryRun {
                    print("[\(agent.displayName)] would remove:\n\(result.diff)")
                } else {
                    print("[\(agent.displayName)] \(result.summary)")
                }
            } catch {
                FileHandle.standardError.write(Data("[\(agent.displayName)] error: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
