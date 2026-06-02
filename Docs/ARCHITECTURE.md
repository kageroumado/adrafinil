# Adrafinil — Architecture

> How Adrafinil is built — runtime components, the sleep-blocking mechanism, detection, the assertion lifecycle, and the Xcode project layout. For the user-facing pitch and feature list, see the [README](../README.md).

Adrafinil prevents system sleep — including clamshell (lid-closed) sleep — only while an AI coding agent has an active session. This document describes the runtime components, the sleep-blocking mechanism, how agent activity is detected, and the assertion lifecycle and safety cutouts.

---

## 1. Components

Three runtime components plus a CLI, across three privilege tiers:

```
┌────────────────────────────────────────────────────────────────────┐
│  Adrafinil.app  (menu bar app, user-facing)                        │
│  • Status item, settings window, installer GUI, lid-open summary   │
│  • Talks to the daemon over XPC; a pure view layer                 │
└───────────────────────┬────────────────────────────────────────────┘
                        │ XPC (NSXPCConnection)
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  AdrafinilDaemon  (LaunchAgent, runs as user, always-on)           │
│  • Reference-counted assertion registry                            │
│  • Process watchers (kqueue NOTE_EXIT + periodic sweep)            │
│  • Thermal monitor (SMC)  • Lid-state monitor (IORegistry)         │
│  • Low-battery monitor    • Lid-close chime  • wake re-assertion   │
│  • Listens on ~/Library/Application Support/Adrafinil/cli.sock     │
└───────────────────────┬────────────────────────────────────────────┘
                        │ XPC (privileged Mach service)
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  AdrafinilHelper  (SMAppService LaunchDaemon, root)                │
│  • The ONLY component that touches sleep-blocking APIs             │
│  • setSleepBlocked(Bool) + sleepBlockedState/version (read-only)   │
│  • Authorizes callers via a code-signing requirement check        │
└────────────────────────────────────────────────────────────────────┘

  adrafinil  (CLI, ships inside the .app, symlinked onto PATH)
  • acquire / release / status / install-hooks / uninstall-hooks /
    daemon-status / version  • connects to the daemon socket; <50ms round-trip
```

Bundle identifiers: app `glass.kagerou.adrafinil`, daemon `…​.daemon`, helper `…​.helper`, CLI `…​.cli` (ships as the lowercase `adrafinil` binary).

### Why three tiers

- **The helper must be privileged** to call sleep-blocking APIs, so it's kept tiny and audited: one mutating endpoint (`setSleepBlocked(Bool)`) plus read-only introspection. It holds **no** policy.
- **The daemon runs as the user** so it can watch user-owned processes, write logs under `~/Library/Application Support`, and receive per-user lid notifications. It's always-on (not just when the app is open) so agents can call `adrafinil acquire` even with no menu bar app running. **All policy lives here** — ref counting, thermal, idle, lid, battery.
- **The app is user-facing** and may quit/relaunch freely; keeping state in the daemon makes it a pure view layer.

---

## 2. Sleep-blocking mechanism

`IOPMAssertionCreateWithName` with the public assertion types (and therefore `caffeinate`) does **not** override clamshell sleep — its own header says "the system may still sleep for lid close." So two mechanisms compose, both held by the helper:

1. **Idle system sleep** (lid open) — a standard reference-counted `IOPMAssertion` (`kIOPMAssertPreventUserIdleSystemSleep`). The kernel auto-releases it if the helper dies. Visible in `pmset -g assertions`.
2. **Clamshell (lid-closed) sleep** — the global `SleepDisabled` power setting, applied by shelling out to `pmset -a disablesleep 1`.

> **Empirical note (macOS 26.3, real-device tested).** Three cleaner in-process mechanisms were each tried and **none** keep a displayless lid-closed Mac awake:
> - Private `RootDomainUserClient` selector 12 (`setClamShellSleepDisable`) — returns success, Mac **still sleeps** (it governs the external-display "clamshell mode" path, not no-display lid-close).
> - Public `IORegistryEntrySetCFProperty(IOPMrootDomain, "SleepDisabled", …)` — `kIOReturnNotPermitted` even as root.
> - `IOPMSetSystemPowerSetting("SleepDisabled", …)` — the per-key call `pmset`'s disablesleep path makes; called alone it returns success but `pmset -g` still shows `SleepDisabled 0` and the Mac sleeps. `pmset` coordinates `IOPMSetPMPreferences` + activation around it, which the single call doesn't reproduce.
>
> Only the full `pmset -a disablesleep 1` was verified to keep the Mac awake (lid closed, no external display, on battery). It is blunt — global, also suppresses idle sleep, persists in the power-management prefs until cleared — but it is the path that works, and it's Apple's own tested implementation. It runs only on block-state flips, so the subprocess cost is negligible. Full investigation: `~/Developer/Research/macos-clamshell-sleep-private-api.md`.

`disablesleep` is **not** cleared on crash and can reset across a sleep/wake cycle. So the helper clears it on release and again on startup (crash recovery), and the daemon re-applies the blocking state on system wake (see §4.5).

**Failure mode**: if the helper crashes while sleep is blocked, the daemon detects it (XPC invalidation) and respawns it; on respawn the helper clears any stale `disablesleep` before re-applying the current state. Worst case: a brief window where sleep is allowed. Acceptable.

---

## 3. Detection — how the daemon knows agents are active

### 3.1 Primary: hooks

The daemon doesn't detect agents directly. Each agent's hook system calls the CLI:

```sh
adrafinil acquire <session-key> --tool <tool> [--reason <text>] [--ttl <seconds>]   # on session start
adrafinil release <session-key>                                                     # on session end
```

The daemon refcounts by session key. **Session id resolution**: the CLI prefers the `session_id` field from the JSON the hook receives on stdin (read by `CLIStdin`), and falls back to a positional arg from a shell env-var expansion. Every Claude-Code-style hook delivers the stdin JSON, so stdin is the reliable, agent-agnostic source — avoiding per-agent env-var naming pitfalls (Claude is `CLAUDE_CODE_SESSION_ID`, not `CLAUDE_SESSION_ID`; Codex exposes `CODEX_THREAD_ID` and documents only the stdin field).

Integrations live in `AdrafinilShared/.../Installer/Integrations/`, one file per agent, each conforming to `AgentIntegration` and delegating to a shared building block (`NestedJSONHookShape`, `FlatJSONHookShape`, `ShellWrapper`, or `FilePlugin`). Adding an agent is a single new file plus one line in the `AgentIntegrations` registry.

### 3.2 Tier-1 agents (full hook support)

These support shell-command hooks with a session-start and (mostly) a session-end event:

| Tool | Config path | Start event | End event |
|------|-------------|-------------|-----------|
| Claude Code | `~/.claude/settings.json` | `UserPromptSubmit` | `Stop` + `Notification`[`idle_prompt`] |
| Codex | `~/.codex/hooks.json` | `SessionStart` | — (process-exit; `Stop` is per-turn, see §3.5) |
| Cursor | `~/.cursor/hooks.json` | `sessionStart` | `sessionEnd` |
| Gemini CLI | `~/.gemini/settings.json` | `SessionStart` | `SessionEnd` |

Claude Code, Codex, and Gemini CLI share a nested JSON shape (`{"hooks": {event: [{"hooks": [{type, command}]}]}}`); Cursor uses a flatter shape (`{"command": …}` entries directly). Only Claude Code also exposes a real session-id env var; the others deliver the id only on stdin.

**Claude Code holds are activity-scoped** (others are still session-scoped). It acquires on
`UserPromptSubmit` (a turn begins) and releases on `Stop` (the agent finishes responding,
`reason: 'completed'` in the query loop), so an open-but-idle session at the prompt holds nothing
and the Mac can sleep — only an actively-working turn keeps it awake. An **Esc-interrupt** is the one
turn-end that fires no `Stop` (the abort short-circuits it), and Claude Code has no interrupt hook.
The reliable catch is the daemon's **CPU-idle sweep** (§4): an interrupted session's process tree
drops to ~idle and the sweep releases it after the idle window. The `Notification`-matched-`idle_prompt`
release hook is a best-effort fast-path (Claude's "waiting for input" notification is gated by
version/focus/channel and often doesn't fire, so it isn't relied upon). The process-exit watcher
(§3.4) covers a terminal closed mid-turn, so no `SessionEnd` hook is needed. Upgrading strips the legacy `SessionStart`/`SessionEnd`
entries (the shape's `obsoleteEvents`) so a stale `SessionStart` → acquire can't re-pin the whole
session. Codex/Cursor/Gemini per-turn event names aren't device-verified yet, so they stay
session-scoped with the CPU-idle sweep as their idle backstop.

### 3.3 Tier-2 agents (partial / non-trivial integration)

| Tool | Strategy |
|------|----------|
| Crush | Only `PreToolUse` exists. Use it to `acquire`; release via the process-exit watcher. Config `~/.config/crush/crush.json`. |
| Aider | No hooks. A shell alias in `~/.zshrc`/`~/.bashrc` wraps `aider` with acquire/release (`~/.local/bin/aider-adrafinil`). |
| Hermes | A **shell hook** in `~/.hermes/config.yaml` (`hooks.on_session_start`/`on_session_end`), plus an approval in `~/.hermes/shell-hooks-allowlist.json` (first-use consent). Runs in CLI + Gateway; session id on stdin. Device-verified — Hermes's other two hook systems (Python plugins, gateway-only `HOOK.yaml`) don't fit. |
| OpenCode | TS plugin at `~/.config/opencode/plugins/adrafinil.ts`. Acquire on `session.created` (id = `event.properties.info.id`); release via the process-exit watcher (`session.idle` is per-turn). |
| Cline | Shell-alias wrapper in `~/.zshrc`/`~/.bashrc`. Limited: misses in-editor VS Code sessions — Cline's native `~/Documents/Cline/Rules/Hooks/` would be the proper path. |
| Pi | TS extension at `~/.pi/agent/extensions/adrafinil.ts`; `pi.on("session_start"/"session_shutdown")`. |

### 3.4 Fallback: process sniffing

The daemon maps known agent binary names to their `AgentKind` (`AgentKind.byBinaryName`). A kqueue watcher fires `NOTE_EXIT` on watched PIDs; a periodic sweep (every 30s) catches anything launched between events and re-arms watches. This both force-releases assertions when an owning process dies without firing its end hook, and optionally (off by default) auto-acquires for sniffed agents with no hook installed.

### 3.5 Codex special case

Verified against Codex 0.135.0 on a real device:

1. **No session-end hook.** `Stop` fires per *turn*, not at session end, and there's no session-end event. So Adrafinil installs **only** a `SessionStart` → acquire hook and releases on process exit (§3.4). A `Stop` → release would drop the assertion after the first turn.
2. **Hooks fire only in the interactive TUI — not `codex exec`.** The non-interactive path doesn't engage the hook runtime. So for `codex exec`, capture relies on process-sniffing (the daemon sees the `codex` process and auto-acquires). This makes process-sniffing the recommended capture mode for Codex.
3. **Hook trust.** Codex won't run a command hook until its exact definition is trusted (hash-based) via `/hooks` in the TUI. Adrafinil can't trust on the user's behalf, so the installer surfaces this.

### 3.6 Subagent and resume semantics

For Claude Code, every turn re-fires `UserPromptSubmit` → acquire and `Stop` → release on the *same* session key, so a multi-turn session cycles acquire→release→acquire harmlessly; subagents run inside a turn (their `SubagentStop` is not wired). For the session-scoped agents, `SessionStart` fires on resume and clear, and subagents fire their own start/end. Reference counting handles all of it: each acquire is keyed by `(tool, session_key)`, release with the same key is idempotent, a re-acquire of a live key just refreshes its activity timestamp, and releases for unknown keys are warnings, not errors.

---

## 4. Assertion lifecycle and safeties

### 4.1 State

```swift
struct Assertion {
    let key: String          // tool:session_id
    let tool: String
    let reason: String?
    let pid: pid_t           // caller PID
    let processName: String  // resolved from PID
    let acquiredAt: Date
    var lastActivityAt: Date // advanced by the CPU sampler
    var expiresAt: Date?     // set when --ttl is passed
}
```

`AssertionRegistry` is an actor; `isBlocking` is `!assertions.isEmpty`. It emits the new value of `isBlocking` on an `AsyncStream` whenever it flips. The daemon iterates that single stream and drives the helper serially, so the helper never sees a stale or out-of-order value. `isBlocking` true → `setSleepBlocked(true)`; false → `setSleepBlocked(false)`.

### 4.2 Idle release

A periodic check (every 30s) releases an assertion when: its owning PID is gone; its process *tree* has stayed below a CPU-rate threshold (default 3% of a core) for ≥ `idleReleaseSeconds` (default 90, configurable); or its `--ttl` deadline has passed. This is the reliable Esc-interrupt catch. CPU is sampled with `proc_pidinfo(PROC_PIDTASKINFO)` summed over the agent process and all descendants (so a long tool call with a busy child still reads as active), and turned into a *rate* between ticks — an absolute-change rule would never fire, because an idle `claude` TUI still burns ~1% CPU. A max-age backstop releases assertions with an unresolved PID and a missed end hook so a leak can't pin sleep forever.

### 4.3 Thermal cutout

While the lid is closed AND ≥1 assertion is held, the daemon polls the SMC (sensor `TC0P`, CPU proximity; threshold 80°C default, configurable 70–95°C). On crossing it releases **all** assertions, logs a `thermalCutout` event, allows sleep, and records a cutout entry for the lid-open summary — so a bag-bound Mac can't cook itself. SMC access is public API (open `AppleSMC`, keyed read), no entitlements.

### 4.4 Lid-close audio cue

Lid-state changes are observed via IORegistry notifications on `AppleClamshellState`. On open → closed with `isBlocking == true`, a short synthesized two-tone descending chime (G5 → D5, ~0.4s) plays — recognizably intentional rather than a system error sound, generated at runtime (no bundled audio file). It respects system volume and skips if muted; the user can instead pick a built-in macOS system sound. On closed → open after a held period, the lid-open summary is shown.

### 4.5 Wake re-assertion

`disablesleep` can be reset by the kernel across a sleep/wake cycle. The daemon registers for system power notifications (`IORegisterForSystemPower`) and, on `kIOMessageSystemHasPoweredOn`, re-pushes the current blocking state to the helper. The helper's `set` is idempotent, so this is a no-op when nothing was lost and a repair when it was.

### 4.6 Low-battery cutout

The battery sibling of the thermal cutout: because `disablesleep` blocks the global sleep flag, a kept-awake lid-closed Mac on battery would otherwise drain to a hard shutdown. While **on battery** AND lid closed AND ≥1 assertion is held, the daemon polls the internal battery (`IOPSCopyPowerSourcesInfo`; threshold 20% default, configurable 5–50%). On crossing it releases **all** assertions, logs a `lowBatteryCutout` event, allows sleep, and records a cutout entry — so normal low-power sleep takes over with charge to spare. On AC there's no drain risk, so it never fires. The decision lives in `LowBatteryCutoutEvaluator` (unit-tested).

---

## 5. UX

- **Menu bar status item** — idle (outlined moon), active (filled sun, optionally badged with the assertion count), or cutout (red, last 30s after a thermal/low-battery trigger, then reverts). Clicking opens a popover listing active agents (tool · duration · reason), with "Force sleep now" and "Settings…", plus lid state and CPU temp.
- **Settings window** — tabs General / Agents / Safety / About. The Agents tab shows each detected agent's install state (installed / not installed / modified externally) with a per-agent toggle and a reveal-in-Finder link.
- **Lid-open summary** — a brief top-right panel after a closed-with-assertions period: which agents ran and for how long, peak CPU temp, and whether a cutout fired. Auto-dismisses.
- **First-run installer** — no privileged work happens before the user proceeds: helper/daemon registration (`SMAppService`), the CLI PATH symlink, and hook installation are each triggered by explicit buttons. Auto-detected agents are shown as a checklist with a per-agent diff preview.

---

## 6. CLI

```
adrafinil acquire <session-key> [--tool <name>] [--reason <text>] [--ttl <seconds>]
adrafinil release <session-key>
adrafinil status [--json]
adrafinil install-hooks [--tool <name>] [--dry-run]
adrafinil uninstall-hooks [--tool <name>]
adrafinil daemon-status
adrafinil version
```

`acquire`/`release` connect to the daemon socket and exit (<50ms target). If the daemon isn't running, the CLI warns and exits 0 — it never fails the agent. `--ttl` is a hard deadline after which the daemon auto-releases. `release` is idempotent; unknown keys warn and exit 0. `install-hooks`/`uninstall-hooks` mirror the GUI installer (so the CLI alone suffices for headless setups); `--dry-run` prints diffs without writing.

**Wire protocol**: length-prefixed JSON over a Unix socket at `~/Library/Application Support/Adrafinil/cli.sock`.

```json
// request
{"op": "acquire", "key": "claude-code:abc123", "tool": "claude-code", "reason": "session", "pid": 12345, "ttl": null}
// response
{"ok": true, "blockingState": true, "assertionCount": 1}
```

---

## 7. Persistence

`~/Library/Application Support/Adrafinil/`:
- `config.json` — user settings.
- `cli.sock` — daemon socket.
- `state.json` — current assertions, so the daemon resumes after a crash without losing live agent sessions.
- `events.log` — append-only JSON-lines log (acquire, release, cutouts, lid open/close). Rotated at 10MB to `events.log.1`. Feeds the lid-open summary.

---

## 8. Xcode project layout

`Adrafinil.xcodeproj` contains **five targets** (four products + a test bundle) and consumes one local Swift package:

| Target | Kind | Product | Bundle ID |
|--------|------|---------|-----------|
| `Adrafinil` | App | `Adrafinil.app` | `glass.kagerou.adrafinil` |
| `AdrafinilDaemon` | Command-line tool | `AdrafinilDaemon` | `glass.kagerou.adrafinil.daemon` |
| `AdrafinilHelper` | Command-line tool | `AdrafinilHelper` | `glass.kagerou.adrafinil.helper` |
| `AdrafinilCLI` | Command-line tool | `adrafinil` (lowercase) | `glass.kagerou.adrafinil.cli` |
| `AdrafinilTests` | Unit test bundle | — | `glass.kagerou.AdrafinilTests` |

`AdrafinilShared` is a local Swift package (`AdrafinilShared/Package.swift`); each non-test target links it (no embed — it's a static library). The package declares a macOS 14 minimum so the shared code stays portable; the app and tools target macOS 26.4.

The project uses **Xcode filesystem-synchronized groups** (`PBXFileSystemSynchronizedRootGroup`) for every target — files added or removed under a target's source folder are picked up automatically, with no file list in the pbxproj to maintain.

### 8.1 Shared build settings

Applied at the project level and inherited by all non-shared targets:

- `MACOSX_DEPLOYMENT_TARGET = 26.4`
- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = complete`
- `ENABLE_HARDENED_RUNTIME = YES`
- `CODE_SIGN_STYLE = Automatic`

### 8.2 Directory layout

```
adrafinil/
├── AdrafinilShared/                  ← local Swift package
│   ├── Package.swift
│   ├── Sources/AdrafinilShared/
│   │   ├── Constants.swift
│   │   ├── Models/                   ← AgentKind, Assertion, AdrafinilSettings
│   │   ├── IPC/                      ← wire formats, XPC protocols, CallerVerifier
│   │   ├── CLI/                      ← ArgParser
│   │   ├── Installer/                ← HookInstaller, InstallState, Integrations/
│   │   ├── Policy/                   ← pure, unit-tested cutout/idle/lid evaluators
│   │   └── ProcessResolver.swift
│   └── Tests/AdrafinilSharedTests/   ← the bulk of the unit tests
├── Adrafinil/                        ← app target sources (menu bar UI, installer, settings)
├── AdrafinilDaemon/                  ← daemon: registry, monitors, IPC, persistence, audio
├── AdrafinilHelper/                  ← privileged helper: SleepBlocker + XPC listener
├── AdrafinilCLI/                     ← the `adrafinil` binary: subcommands + socket client
└── AdrafinilTests/                   ← app-level test target
```

### 8.3 Embedding the tools inside the app bundle

Command-line-tool products can't be added through "Frameworks, Libraries, and Embedded Content"; they're embedded via Copy Files build phases on the app target (which also depends on all three tools, so they build first):

| Product | Destination (`dstSubfolderSpec`) | Path |
|---------|----------------------------------|------|
| `AdrafinilHelper` | Wrapper | `Contents/Library/LaunchDaemons` |
| `AdrafinilDaemon` | Wrapper | `Contents/Library/LaunchAgents` |
| `adrafinil` (CLI) | Wrapper | `Contents/Helpers` |

The CLI goes in `Contents/Helpers` rather than `Contents/MacOS` because a lowercase `adrafinil` would collide case-insensitively with the `Adrafinil` app binary. `CLISymlinker` looks there first when symlinking the CLI onto `PATH`.

Each tool's launchd plist sits next to its binary in the bundle (`AdrafinilHelper/LaunchDaemon.plist` → `Contents/Library/LaunchDaemons/`, `AdrafinilDaemon/LaunchAgent.plist` → `Contents/Library/LaunchAgents/`). These are carried in by the synchronized groups' membership-exception sets (excluded from compilation, routed into the corresponding Copy Files phase), so no manual Copy Files entry is needed. `HelperInstaller` registers them by name:

```swift
SMAppService.daemon(plistName: "LaunchDaemon.plist")
SMAppService.agent(plistName: "LaunchAgent.plist")
```

### 8.4 Entitlements & Info.plists

- **Adrafinil.app** — `Adrafinil/Adrafinil.entitlements`; App Sandbox **off** (needed for `SMAppService` and spawning processes).
- **AdrafinilHelper** — `Info.plist` declares `SMAuthorizedClients` (`identifier "glass.kagerou.adrafinil" and anchor apple generic`); privilege comes from running as a LaunchDaemon. No entitlements file.
- **AdrafinilDaemon** — `Info.plist` with `LSBackgroundOnly`; no `SMAuthorizedClients`, no entitlements file.
- **AdrafinilCLI** — no entitlements file.

### 8.5 Sanity check after a clean checkout

1. `Cmd+B` the **Adrafinil** scheme. All five targets build (set a development team for signing, or pass `CODE_SIGNING_ALLOWED=NO` for a headless compile check — see the README).
2. Run the app. The menu bar icon appears; first launch opens the Setup window, which calls `SMAppService.register()` for the helper and daemon — macOS prompts for approval in System Settings → Login Items.
3. Approve both. The status icon then reflects daemon state.
4. From a terminal: `adrafinil status` prints the daemon status.
5. `cd AdrafinilShared && swift test` runs the shared unit tests without Xcode.

---

## 9. Naming

**Adrafinil** is a eugeroic prodrug to modafinil, fitting the nootropic-app theme. Less well-known than Modafinil itself, which is the point — searchable, ownable, distinctive. The app keeps your machine awake only when it actually has work to do.
