import Testing
@testable import AdrafinilShared

@Suite("AgentKind")
struct AgentKindTests {

    @Test func everyAgentHasDisplayName() {
        for k in AgentKind.allCases {
            #expect(!k.displayName.isEmpty, "\(k) missing displayName")
        }
    }

    @Test func everyAgentHasAtLeastOneBinaryName() {
        for k in AgentKind.allCases {
            #expect(!k.binaryNames.isEmpty, "\(k) has no binaryNames")
        }
    }

    @Test func tierClassificationCoversAllAgents() {
        let tier1: Set<AgentKind> = [.claudeCode, .codex, .cursor, .geminiCLI, .goose]
        let tier2: Set<AgentKind> = [.crush, .aider, .hermes, .openCode, .cline]
        #expect(tier1.union(tier2) == Set(AgentKind.allCases))
        for k in tier1 { #expect(k.tier == 1, "\(k) should be tier 1") }
        for k in tier2 { #expect(k.tier == 2, "\(k) should be tier 2") }
    }

    @Test func rawValuesAreKebabCaseAndUnique() {
        let raws = AgentKind.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for raw in raws {
            #expect(raw == raw.lowercased())
            #expect(!raw.contains(" "))
        }
    }

    @Test func aiderAndClineAreTier2() {
        #expect(AgentKind.aider.tier == 2)
        #expect(AgentKind.cline.tier == 2)
    }

    @Test func allBinaryNamesAreNonEmpty() {
        for k in AgentKind.allCases {
            for name in k.binaryNames {
                #expect(!name.isEmpty, "\(k) has an empty binary name")
            }
        }
    }

    @Test func allBinaryNamesUnionCoversAllKnownAgents() {
        let allNames = Set(AgentKind.allCases.flatMap { $0.binaryNames })
        #expect(allNames.contains("claude"))
        #expect(allNames.contains("codex"))
        #expect(allNames.contains("aider"))
        #expect(allNames.contains("goose"))
        #expect(allNames.contains("opencode"))
    }

    @Test func binaryNamesAreGloballyUnique() {
        // The daemon's sniff sweep builds a binary-name → AgentKind map; a collision would
        // silently mis-attribute an auto-acquired assertion to the wrong agent.
        let all = AgentKind.allCases.flatMap { $0.binaryNames }
        #expect(Set(all).count == all.count, "binary names collide across agents: \(all)")
    }

    @Test func unknownRawValueIsNil() {
        #expect(AgentKind(rawValue: "not-an-agent") == nil)
    }

    @Test func rawValueRoundTrips() {
        for k in AgentKind.allCases {
            #expect(AgentKind(rawValue: k.rawValue) == k)
        }
    }

    @Test func forRunningProcessMatchesBasename() {
        #expect(AgentKind.forRunningProcess(name: "codex", path: "/usr/local/bin/codex") == .codex)
    }

    @Test func forRunningProcessMatchesVersionedPathComponent() {
        let kind = AgentKind.forRunningProcess(name: "2.1.156", path: "/Users/u/.local/share/claude/versions/2.1.156")
        #expect(kind == .claudeCode)
    }

    @Test func forRunningProcessReturnsNilForUnknown() {
        #expect(AgentKind.forRunningProcess(name: "python3", path: "/usr/bin/python3") == nil)
    }
}
