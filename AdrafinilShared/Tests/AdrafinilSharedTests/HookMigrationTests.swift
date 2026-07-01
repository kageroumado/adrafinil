import Foundation
import Testing
@testable import AdrafinilShared

@Suite("HookMigration")
struct HookMigrationTests {
    private let states: [(agent: AgentKind, state: HookInstallState)] = [
        (.claudeCode, .installed),
        (.codex, .modifiedExternally), // old acquire-only shape after the Stop-release upgrade
        (.cursor, .notInstalled),
        (.geminiCLI, .configUnreadable),
    ]

    @Test
    func `build bump reinstalls managed agents only`() {
        let agents = HookMigration.agentsToReinstall(
            lastBuild: "9", currentBuild: "10", isFirstRun: false, states: states,
        )
        // Claude (installed) + Codex (drifted) reinstall; Cursor (not ours) and Gemini (unreadable) skip.
        #expect(agents == [.claudeCode, .codex])
    }

    @Test
    func `same build is a no-op`() {
        let agents = HookMigration.agentsToReinstall(
            lastBuild: "10", currentBuild: "10", isFirstRun: false, states: states,
        )
        #expect(agents.isEmpty)
    }

    @Test
    func `first run never migrates`() {
        // Brand-new install: the installer sets up current hooks; migrating would be redundant.
        let agents = HookMigration.agentsToReinstall(
            lastBuild: nil, currentBuild: "10", isFirstRun: true, states: states,
        )
        #expect(agents.isEmpty)
    }

    @Test
    func `upgrade from a pre-migrator build (nil last) migrates`() {
        // The migrator never ran before, but the user already had hooks → reinstall to add the new shape.
        let agents = HookMigration.agentsToReinstall(
            lastBuild: nil, currentBuild: "10", isFirstRun: false, states: states,
        )
        #expect(agents == [.claudeCode, .codex])
    }

    @Test
    func `nothing managed yields empty even on a build bump`() {
        let agents = HookMigration.agentsToReinstall(
            lastBuild: "9", currentBuild: "10", isFirstRun: false,
            states: [(.cursor, .notInstalled), (.geminiCLI, .configUnreadable)],
        )
        #expect(agents.isEmpty)
    }
}
