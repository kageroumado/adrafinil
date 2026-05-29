# Xcode Project Structure

`Adrafinil.xcodeproj` contains **five targets** (four products + a test bundle) and consumes one local Swift package:

| Target | Kind | Product | Bundle ID |
|--------|------|---------|-----------|
| `Adrafinil` | App | `Adrafinil.app` | `glass.kagerou.adrafinil` |
| `AdrafinilDaemon` | Command-line tool | `AdrafinilDaemon` | `glass.kagerou.adrafinil.daemon` |
| `AdrafinilHelper` | Command-line tool | `AdrafinilHelper` | `glass.kagerou.adrafinil.helper` |
| `AdrafinilCLI` | Command-line tool | `adrafinil` (lowercase) | `glass.kagerou.adrafinil.cli` |
| `AdrafinilTests` | Unit test bundle | — | `glass.kagerou.AdrafinilTests` |

`AdrafinilShared` is a local Swift package (`AdrafinilShared/Package.swift`), already referenced by the project; each non-test target links it (no embed — it's a static library). The package itself declares a macOS 14 minimum so the shared code stays portable; the app and tools target macOS 26.4.

The project uses **Xcode filesystem-synchronized groups** (`PBXFileSystemSynchronizedRootGroup`) for every target. Files added or removed under a target's source folder are picked up automatically — there is no file list in the pbxproj to maintain.

## Shared build settings

Applied at the project level (and inherited by all non-shared targets):

- `MACOSX_DEPLOYMENT_TARGET = 26.4`
- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = complete`
- `ENABLE_HARDENED_RUNTIME = YES`
- `CODE_SIGN_STYLE = Automatic`

## Directory layout

```
adrafinil/
├── AdrafinilShared/                  ← local Swift package
│   ├── Package.swift
│   ├── Sources/AdrafinilShared/
│   │   ├── Constants.swift
│   │   ├── Models/                   ← AgentKind, Assertion, AdrafinilSettings
│   │   ├── IPC/                      ← wire formats, XPC protocols, CallerVerifier
│   │   ├── CLI/                      ← ArgParser
│   │   ├── Installer/                ← HookSpec, HookInstaller, InstallState
│   │   └── ProcessResolver.swift
│   └── Tests/AdrafinilSharedTests/   ← the bulk of the unit tests
├── Adrafinil/                        ← app target sources (menu bar UI, installer, settings)
├── AdrafinilDaemon/                  ← daemon: registry, monitors, IPC, persistence, audio
├── AdrafinilHelper/                  ← privileged helper: SleepBlocker + XPC listener
├── AdrafinilCLI/                     ← the `adrafinil` binary: subcommands + socket client
└── AdrafinilTests/                   ← app-level test target
```

## Embedding the tools inside the app bundle

Command-line-tool products can't be added through "Frameworks, Libraries, and Embedded Content"; they're embedded via Copy Files build phases on the app target (which also depends on all three tools, so they build first). The phases place each product at:

| Product | Destination (`dstSubfolderSpec`) | Path |
|---------|----------------------------------|------|
| `AdrafinilHelper` | Wrapper | `Contents/Library/LaunchDaemons` |
| `AdrafinilDaemon` | Wrapper | `Contents/Library/LaunchAgents` |
| `adrafinil` (CLI) | Wrapper | `Contents/Helpers` |

The CLI goes in `Contents/Helpers` rather than `Contents/MacOS` because a lowercase `adrafinil` would collide case-insensitively with the `Adrafinil` app binary. `CLISymlinker` looks there first when symlinking the CLI onto `PATH`.

Each tool's launchd plist sits next to its binary in the bundle:

- `AdrafinilHelper/LaunchDaemon.plist` → `Contents/Library/LaunchDaemons/LaunchDaemon.plist`
- `AdrafinilDaemon/LaunchAgent.plist` → `Contents/Library/LaunchAgents/LaunchAgent.plist`

These are carried in by the synchronized groups' membership-exception sets (the plists are excluded from compilation and routed into the corresponding Copy Files phase), so no manual Copy Files entry is needed. `HelperInstaller` registers them by name:

```swift
SMAppService.daemon(plistName: "LaunchDaemon.plist")
SMAppService.agent(plistName: "LaunchAgent.plist")
```

## Entitlements & Info.plists

- **Adrafinil.app** — `Adrafinil/Adrafinil.entitlements`; App Sandbox **off** (needed for `SMAppService` and spawning processes).
- **AdrafinilHelper** — `Info.plist` declares `SMAuthorizedClients` (`identifier "glass.kagerou.adrafinil" and anchor apple generic`); privilege comes from running as a LaunchDaemon. No entitlements file.
- **AdrafinilDaemon** — `Info.plist` with `LSBackgroundOnly`; no `SMAuthorizedClients`, no entitlements file.
- **AdrafinilCLI** — no entitlements file.

## Sanity check after a clean checkout

1. `Cmd+B` the **Adrafinil** scheme. All five targets build (set a development team for signing, or pass `CODE_SIGNING_ALLOWED=NO` for a headless compile check — see the README).
2. Run the app. The menu bar icon appears; first launch opens the Setup window, which calls `SMAppService.register()` for the helper and daemon — macOS prompts for approval in System Settings → Login Items.
3. Approve both. The status icon then reflects daemon state.
4. From a terminal: `adrafinil status` prints the daemon status.
5. `cd AdrafinilShared && swift test` runs the shared unit tests without Xcode.
