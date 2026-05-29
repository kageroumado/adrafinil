# Adrafinil

Keep your Mac awake only while AI agents are working.

Adrafinil is a macOS menu bar app that prevents the system from sleeping — including clamshell (lid-closed) sleep — **exclusively while an AI coding agent has an active session**. When no agent is working, sleep behavior is untouched: close the lid and the Mac sleeps normally.

It's the opposite of always-on wake utilities like `caffeinate` or Amphetamine. Adrafinil only intervenes when an agent (Claude Code, Codex, Cursor, …) is mid-task, and gets out of the way the moment that work finishes.

> ⚠️ **Privileged sleep control.** Overriding clamshell sleep requires root. Adrafinil isolates that in a tiny, audited helper that only exposes `setSleepBlocked(Bool)` — all policy lives in an unprivileged daemon. The mechanism is `pmset disablesleep`; see [Docs/SPEC.md](Docs/SPEC.md) §4 for the full rationale and the private-IOPM alternative.

## Features

- **Agent-aware, not always-on.** Sleep is blocked only while ≥1 agent session holds an assertion. Zero sessions → normal sleep, including lid-close.
- **Hook integration for 10 agents.** One-click installer wires Adrafinil into the hook systems of Claude Code, Codex, Cursor, Gemini CLI, Goose, Crush, Aider, Hermes, OpenCode, and Cline.
- **Sub-50ms CLI.** `adrafinil acquire` / `release` are called from agent hooks and round-trip to the daemon in under 50ms, so they never stall an agent's workflow.
- **Reference-counted assertions.** Overlapping sessions stack cleanly; sleep unblocks only when the last one releases.
- **Thermal cutout.** If skin/CPU temperature crosses threshold while the lid is closed, all assertions are force-released so a bag-bound Mac can't cook itself.
- **Idle release.** Assertions whose owning process has died or gone CPU-idle for N minutes are dropped automatically.
- **Process sniffing (optional).** The daemon can auto-acquire when it sees a known agent binary running, even without hooks installed.
- **Lid-close audio + lid-open summary.** A chime confirms an assertion is held when you close the lid (the screen is off, so no notification); reopening shows what ran while you were away, peak temperature, and whether the thermal cutout fired.
- **Clean uninstall.** Removes every hook entry it added across all agent configs.

## Requirements

- **macOS Tahoe (26.0+).** Targets `MACOSX_DEPLOYMENT_TARGET = 26.4`.
- **Xcode 17+** to build, with Swift 6 strict concurrency enabled.
- Admin rights for the standard install (the privileged helper installs via `SMAppService`). A non-admin install path drops the CLI in `~/.local/bin` instead of `/usr/local/bin`.

## Building

```sh
git clone https://github.com/kageroumado/adrafinil.git
cd adrafinil
open Adrafinil.xcodeproj
```

In Xcode, select the **Adrafinil** scheme and Run. You'll need to set a development team for code signing — the daemon (LaunchAgent) and helper (LaunchDaemon) are embedded into the app bundle and registered with the system when the app launches.

For a headless compile check without local signing identities:

```sh
xcodebuild -project Adrafinil.xcodeproj -scheme Adrafinil -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

The shared logic builds and tests standalone as a Swift package:

```sh
cd AdrafinilShared
swift test
```

## How it works

Agents don't talk to Adrafinil directly. Each agent's hook system calls the bundled CLI:

```sh
adrafinil acquire <session-key> --tool claude-code --reason "long build"   # on SessionStart
adrafinil release <session-key>                                            # on SessionEnd
```

The daemon refcounts by session key and asks the helper to block sleep while the count is non-zero. Other subcommands: `status`, `install-hooks`, `uninstall-hooks`, `daemon-status`, `version`.

## Architecture

Four products across three privilege tiers (full detail in [Docs/SPEC.md](Docs/SPEC.md); Xcode project layout in [Docs/TARGETS.md](Docs/TARGETS.md)):

```
┌──────────────────────────────────────────────────────────────┐
│  Adrafinil.app   (menu bar app, user-facing)                 │
│  • Status item, settings, installer GUI, lid-open summary    │
└─────────────────────────────┬────────────────────────────────┘
                              │ XPC
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  AdrafinilDaemon  (LaunchAgent, runs as user, always-on)     │
│  • Reference-counted assertion registry                      │
│  • Process watchers (kqueue NOTE_EXIT + periodic sweep)      │
│  • Thermal monitor (SMC)  • Lid-state monitor (IORegistry)   │
│  • Lid-close chime  • CLI socket at …/Adrafinil/cli.sock     │
└─────────────────────────────┬────────────────────────────────┘
                              │ XPC (privileged Mach service)
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  AdrafinilHelper  (SMAppService LaunchDaemon, root)          │
│  • The ONLY component that touches sleep-blocking APIs       │
│  • setSleepBlocked(Bool) + read-only state/version           │
│  • Verifies caller's code-signing requirement                │
└──────────────────────────────────────────────────────────────┘

  adrafinil  (CLI, ships inside the .app, symlinked onto PATH)
  • acquire / release / status / install-hooks / uninstall-hooks
  • Connects to the daemon socket; <50ms round-trip
```

- **`AdrafinilShared`** — a Swift package shared across every target: data models (`AgentKind`, `Assertion`), the IPC wire formats, `AssertionRegistry`, `CallerVerifier`, the hook-install specs, and the CLI argument parser. This is where the unit tests live.
- **Helper stays trivial to audit.** It holds no policy — ref counting, thermal, idle, and lid logic all live in the daemon. The privileged surface is a single mutating endpoint plus read-only introspection.
- **Daemon is the source of truth.** The app is a pure view layer; it can quit and relaunch freely without affecting held assertions.

## Quirks worth knowing

- **Public IOPM assertions don't beat clamshell sleep.** `IOPMAssertionCreateWithName` with the public types (and therefore `caffeinate`) will not keep a lid-closed Mac awake. Adrafinil's v1 uses `pmset disablesleep 1`, which is blunt (it also disables idle sleep) and *must* be cleared on shutdown or it leaks — the helper resets to `disablesleep 0` on respawn before re-applying state.
- **Daemon handlers run on arbitrary queues.** XPC and socket callbacks can arrive on any dispatch queue, so the assertion registry and shared state are synchronized accordingly. Tread carefully around concurrency when modifying the daemon.
- **The CLI is on a latency budget.** `acquire`/`release` are in the hot path of every agent session, hence static lookups (e.g. `AgentKind.allBinaryNames`) and a thin socket protocol instead of full XPC for the CLI ↔ daemon hop.

## License

[MIT](LICENSE). Do whatever you want, no warranty.

## Acknowledgements

Built by [@kageroumado](https://x.com/kageroumado). The name is a nod to [adrafinil](https://en.wikipedia.org/wiki/Adrafinil) — a wakefulness-promoting prodrug — because the app keeps your machine awake only when it actually has work to do.
