import AdrafinilShared
import Foundation

/// Shared plumbing for `install-hooks` / `uninstall-hooks`.
enum HookCommandSupport {
    /// Resolves `--tool` to an agent, exiting with the valid names on a typo. A misspelled tool
    /// must never silently fan out to every agent — `uninstall-hooks --tool claude` (the raw
    /// value is `claude-code`) would otherwise strip hooks from all of them.
    ///
    /// `--config-dir` names a Claude Code profile directory, so it narrows the target to Claude Code
    /// and refuses any other `--tool` rather than silently ignoring the directory.
    static func targetAgents(_ parser: ArgParser) -> [AgentKind] {
        let hasConfigDir = parser.option("--config-dir") != nil
        guard let raw = parser.option("--tool") else {
            return hasConfigDir ? [.claudeCode] : AgentKind.allCases
        }
        guard let kind = AgentKind(rawValue: raw) else {
            let valid = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("unknown tool '\(raw)' — valid: \(valid)\n".utf8))
            exit(2)
        }
        if hasConfigDir, kind != .claudeCode {
            FileHandle.standardError.write(Data("--config-dir applies to claude-code only\n".utf8))
            exit(2)
        }
        return [kind]
    }

    /// The installer for this invocation, honoring `--config-dir` (a `CLAUDE_CONFIG_DIR` profile).
    /// A flag given with no value parses as a bare flag — refuse it instead of falling back to the
    /// default profile, which would write somewhere the user didn't ask for.
    static func installer(_ parser: ArgParser) -> HookInstaller {
        if parser.flag("--config-dir") {
            FileHandle.standardError.write(Data("--config-dir requires a directory\n".utf8))
            exit(2)
        }
        return HookInstaller(cliPath: canonicalCLIPath(), claudeConfigDir: parser.option("--config-dir"))
    }

    /// Canonical absolute path of this binary, for embedding in hook commands. argv[0] is
    /// whatever the user typed (a bare PATH lookup, a relative path, the ~/.local/bin symlink);
    /// resolving it through `realpath` lands on the in-bundle binary — the same string the GUI
    /// installer writes — so install-state comparisons agree no matter who wrote the hook.
    static func canonicalCLIPath() -> String {
        let argv0 = ProcessInfo.processInfo.arguments[0]
        let absolute: String = if argv0.hasPrefix("/") {
            argv0
        } else if argv0.contains("/") {
            FileManager.default.currentDirectoryPath + "/" + argv0
        } else {
            pathLookup(argv0) ?? argv0
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(absolute, &buf) != nil {
            let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return absolute
    }

    private static func pathLookup(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

enum InstallHooksCommand {
    static func run(args: [String]) throws {
        let parser = ArgParser(args: args)
        let dryRun = parser.flag("--dry-run")
        let withMCP = parser.flag("--mcp")

        let installer = HookCommandSupport.installer(parser)

        for agent in HookCommandSupport.targetAgents(parser) {
            do {
                let result = try installer.install(for: agent, dryRun: dryRun)
                if dryRun {
                    print("[\(agent.displayName)] would write:\n\(result.diff)")
                } else {
                    print("[\(agent.displayName)] \(result.summary)")
                }
                // `--mcp`: also register the `adrafinil mcp` server, for agents with verified MCP
                // support. Only after the hooks went in, so an undetected agent gets neither.
                if withMCP, installer.supportsMCP(for: agent) {
                    let mcp = try installer.installMCP(for: agent, dryRun: dryRun)
                    if dryRun {
                        print("[\(agent.displayName)] MCP would write:\n\(mcp.diff)")
                    } else {
                        print("[\(agent.displayName)] MCP: \(mcp.summary)")
                    }
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
        let dryRun = parser.flag("--dry-run")
        let withMCP = parser.flag("--mcp")
        let installer = HookCommandSupport.installer(parser)
        for agent in HookCommandSupport.targetAgents(parser) {
            do {
                let result = try installer.uninstall(for: agent, dryRun: dryRun)
                if dryRun {
                    print("[\(agent.displayName)] would remove:\n\(result.diff)")
                } else {
                    print("[\(agent.displayName)] \(result.summary)")
                }
                if withMCP, installer.supportsMCP(for: agent) {
                    let mcp = try installer.uninstallMCP(for: agent, dryRun: dryRun)
                    if dryRun {
                        print("[\(agent.displayName)] MCP would remove:\n\(mcp.diff)")
                    } else {
                        print("[\(agent.displayName)] MCP: \(mcp.summary)")
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("[\(agent.displayName)] error: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
