import Testing
@testable import AdrafinilShared

@Suite("AgentKind")
struct AgentKindTests {
    @Test
    func `every agent has display name`() {
        for k in AgentKind.allCases {
            #expect(!k.displayName.isEmpty, "\(k) missing displayName")
        }
    }

    @Test
    func `every agent has at least one binary name`() {
        for k in AgentKind.allCases {
            #expect(!k.binaryNames.isEmpty, "\(k) has no binaryNames")
        }
    }

    @Test
    func `tier classification covers all agents`() {
        let tier1: Set<AgentKind> = [.claudeCode, .codex, .cursor, .geminiCLI]
        let tier2: Set<AgentKind> = [.aider, .hermes, .openCode, .cline, .pi]
        #expect(tier1.union(tier2) == Set(AgentKind.allCases))
        for k in tier1 {
            #expect(k.tier == 1, "\(k) should be tier 1")
        }
        for k in tier2 {
            #expect(k.tier == 2, "\(k) should be tier 2")
        }
    }

    @Test
    func `raw values are kebab case and unique`() {
        let raws = AgentKind.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for raw in raws {
            #expect(raw == raw.lowercased())
            #expect(!raw.contains(" "))
        }
    }

    @Test
    func `aider and cline are tier 2`() {
        #expect(AgentKind.aider.tier == 2)
        #expect(AgentKind.cline.tier == 2)
    }

    @Test
    func `all binary names are non empty`() {
        for k in AgentKind.allCases {
            for name in k.binaryNames {
                #expect(!name.isEmpty, "\(k) has an empty binary name")
            }
        }
    }

    @Test
    func `all binary names union covers all known agents`() {
        let allNames = Set(AgentKind.allCases.flatMap(\.binaryNames))
        #expect(allNames.contains("claude"))
        #expect(allNames.contains("codex"))
        #expect(allNames.contains("aider"))
        #expect(allNames.contains("pi"))
        #expect(allNames.contains("opencode"))
    }

    @Test
    func `binary names are globally unique`() {
        // The daemon's sniff sweep builds a binary-name → AgentKind map; a collision would
        // silently mis-attribute an auto-acquired assertion to the wrong agent.
        let all = AgentKind.allCases.flatMap(\.binaryNames)
        #expect(Set(all).count == all.count, "binary names collide across agents: \(all)")
    }

    @Test
    func `unknown raw value is nil`() {
        #expect(AgentKind(rawValue: "not-an-agent") == nil)
    }

    @Test
    func `raw value round trips`() {
        for k in AgentKind.allCases {
            #expect(AgentKind(rawValue: k.rawValue) == k)
        }
    }

    @Test
    func `for running process matches basename`() {
        #expect(AgentKind.forRunningProcess(name: "codex", path: "/usr/local/bin/codex") == .codex)
    }

    /// Homebrew's cask symlinks `codex` → a triple-suffixed real binary, and `proc_pidpath` resolves
    /// the symlink, so the daemon sees `codex-aarch64-apple-darwin` (or the x86_64 variant) as the
    /// process basename. Both must resolve to `.codex`, or every Homebrew install is unwatchable and
    /// its hold never releases until the 24h backstop. (npm spawns a binary actually named `codex`.)
    @Test
    func `for running process matches homebrew triple-suffixed codex`() {
        let arm = "/opt/homebrew/Caskroom/codex/0.136.0/codex-aarch64-apple-darwin"
        #expect(AgentKind.forRunningProcess(name: "codex-aarch64-apple-darwin", path: arm) == .codex)
        let intel = "/usr/local/Caskroom/codex/0.136.0/codex-x86_64-apple-darwin"
        #expect(AgentKind.forRunningProcess(name: "codex-x86_64-apple-darwin", path: intel) == .codex)
        // The owning-PID walk uses the same name set; the suffixed basename must satisfy it too.
        #expect(ProcessResolver.pathMatchesAgent(arm, names: AgentKind.allBinaryNames))
    }

    @Test
    func `for running process matches versioned path component`() {
        let kind = AgentKind.forRunningProcess(name: "2.1.156", path: "/Users/u/.local/share/claude/versions/2.1.156")
        #expect(kind == .claudeCode)
    }

    @Test
    func `for running process returns nil for unknown`() {
        #expect(AgentKind.forRunningProcess(name: "python3", path: "/usr/bin/python3") == nil)
    }

    @Test
    func `only hermes is gateway scoped`() {
        // Hermes runs as one shared 24/7 gateway process; everything else is one process per session.
        for k in AgentKind.allCases {
            #expect(k.isGatewayScoped == (k == .hermes), "\(k) gateway-scoping is wrong")
        }
        #expect(AgentKind.hermes.gatewayPIDFileRelativePath == ".hermes/gateway.pid")
    }

    @Test
    func `argv matches hermes gateway`() {
        let argv = ["python", "-m", "hermes_cli.main", "gateway", "run", "--replace"]
        #expect(AgentKind.forRunningProcess(argv: argv) == .hermes)
    }

    @Test
    func `argv matches hermes desktop dashboard`() {
        let argv = [
            "python",
            "-m",
            "hermes_cli.main",
            "dashboard",
            "--no-open",
            "--tui",
            "--host",
            "127.0.0.1",
            "--port",
            "9120",
        ]
        #expect(AgentKind.forRunningProcess(argv: argv) == .hermes)
    }

    @Test
    func `argv does not match unrelated python`() {
        #expect(AgentKind.forRunningProcess(argv: ["python", "-m", "http.server"]) == nil)
        #expect(AgentKind.forRunningProcess(argv: []) == nil)
    }

    @Test
    func `argv requires all markers in A group`() {
        // hermes_cli.main alone (no gateway/dashboard subcommand) shouldn't match — e.g. `--help`.
        #expect(AgentKind.forRunningProcess(argv: ["python", "-m", "hermes_cli.main", "--help"]) == nil)
    }

    @Test
    func `argv matched agents is exactly the argv marker agents`() {
        #expect(Set(AgentKind.argvMatchedAgents) == Set(AgentKind.allCases.filter { $0.argvMarkers != nil }))
        #expect(AgentKind.argvMatchedAgents.contains(.hermes))
    }
}
