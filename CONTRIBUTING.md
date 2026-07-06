# Contributing

Bug reports, fixes, and new agent integrations are welcome.

## Bugs

Open an issue with the Bug report template. Include the `adrafinil status` output and the log excerpt it asks for. That's what makes a sleep/wake bug diagnosable. Security issues go through [SECURITY.md](SECURITY.md), not public issues.

## Build

App, daemon, helper, and CLI:

```sh
xcodebuild -scheme Adrafinil -destination 'platform=macOS' build
```

Shared core and tests:

```sh
cd AdrafinilShared && swift test
```

## Style

SwiftFormat, checked in CI (`swiftformat --lint .`). Enable the pre-commit hook once so staged Swift is formatted for you:

```sh
git config core.hooksPath .githooks
```

Or just run `swiftformat .` before committing.

## Layout

- `Adrafinil/` — menu-bar app and Settings.
- `AdrafinilDaemon/` — LaunchAgent. Holds the assertion registry and all policy.
- `AdrafinilHelper` — root LaunchDaemon. Only does `setSleepBlocked(_:)`. Keep it tiny.
- `AdrafinilCLI/` — the `adrafinil` CLI that agent hooks call.
- `AdrafinilShared/` — shared, tested core. Agent integrations live in `Installer/Integrations/`.

## New agent integration

One file in `Installer/Integrations/`, registered in the `AgentIntegrations` switch. Users can already wire up any agent by hand via Settings → Agents → Add your own agent. A built-in integration is only worth it when the agent's hook-config format is stable.

## Pull requests

Use the template. Reference the issue you fix. Keep it focused. Test on real hardware with a real agent, not just a build. `swift test` and `swiftformat --lint .` must pass. Fill in the Authorship section: agent, model, and whether the session was attended or automatic.

Contributions are MIT-licensed.
