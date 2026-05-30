# Adrafinil — Specification

> Keep your Mac awake only while AI agents are working.

A macOS menu bar app that prevents the system from sleeping — including clamshell (lid-closed) sleep — exclusively while an AI coding agent has an active session. When no agent is working, sleep behavior is untouched: close the lid, the Mac sleeps normally.

This document describes the system as built. Section numbers are referenced from doc comments throughout the source (`SPEC §X.Y`), so they are kept stable.

---

## 1. Positioning

- **Pitch**: "Amphetamine for the agent era — only stays awake when your agent is working."
- **What it replaces**: `caffeinate`, `pmset disablesleep`, Amphetamine, KeepingYouAwake, the "leave my $3000 laptop open on a bench" workflow.
- **Why**: AI coding agents (Claude Code, Codex, Cursor) run long autonomous tasks. People close their laptops and lose work. Existing wake apps are dumb (always-on or timer-based). Adrafinil knows when an agent is active and only intervenes then.

Open source, MIT.

---

## 2. Goals and non-goals

### Goals

- **G1**: Prevent system sleep (including clamshell) while ≥1 active assertion is held.
- **G2**: Allow normal sleep behavior when no assertions are held.
- **G3**: One-click GUI installer that wires the app into every detected agent's hook system.
- **G4**: CLI hook entry point (`adrafinil acquire` / `release`) that completes in <50ms so agents don't stall.
- **G5**: Audio feedback at lid-close when an assertion is held (no notifications — screen is off).
- **G6**: Thermal cutout — force-release all assertions if CPU temperature crosses threshold while clamshell.
- **G7**: Idle release — drop assertions whose owning process is dead or has been CPU-idle for N minutes.
- **G8**: Clean uninstall that removes hook entries from every agent's config.

### Non-goals

- **N1**: Not a general wake utility. No always-on mode, no timer-based wake. (If you want that, use Amphetamine.)
- **N2**: No iOS, no Linux, no Windows.
- **N3**: No remote/cloud features. No telemetry.
- **N4**: No paid tier. Open source, free, no upsell.
- **N5**: Does not try to wake a sleeping Mac. Only prevents sleep in the first place.

---

## 3. Architecture

Three runtime components plus a CLI, mapped to Xcode targets (see [TARGETS.md](TARGETS.md)):

```
┌────────────────────────────────────────────────────────────────────┐
│  Adrafinil.app  (menu bar app, user-facing)                        │
│  • Status item, settings window, installer GUI, lid-open summary   │
│  • Talks to daemon over XPC                                        │
└───────────────────────┬────────────────────────────────────────────┘
                        │ XPC (NSXPCConnection)
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  AdrafinilDaemon  (LaunchAgent, runs as user, always-on)           │
│  • Reference-counted assertion registry                            │
│  • Process watchers (kqueue NOTE_EXIT, periodic sweep)             │
│  • Thermal monitor (SMC reads)                                     │
│  • Lid-state monitor (IORegistry "AppleClamshellState" notify)     │
│  • Audio feedback at lid-close                                     │
│  • Talks to helper over XPC (Mach service)                         │
│  • Listens on ~/Library/Application Support/Adrafinil/cli.sock     │
└───────────────────────┬────────────────────────────────────────────┘
                        │ XPC (privileged Mach service)
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  AdrafinilHelper  (privileged tool, SMAppService LaunchDaemon)     │
│  • The ONLY component that touches sleep-blocking APIs             │
│  • setSleepBlocked(Bool) + sleepBlockedState/version (read-only)   │
│  • Authorizes callers via code-signing requirement check          │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  adrafinil  (CLI, ships inside the .app, symlinked onto PATH)      │
│  • Subcommands: acquire, release, status, install-hooks,           │
│    uninstall-hooks, daemon-status, version                         │
│  • Connects to daemon socket; <50ms round-trip                     │
└────────────────────────────────────────────────────────────────────┘
```

### 3.1 Bundle identifiers

- App: `glass.kagerou.adrafinil`
- Daemon: `glass.kagerou.adrafinil.daemon`
- Helper: `glass.kagerou.adrafinil.helper`
- CLI: `glass.kagerou.adrafinil.cli` (token ID only; ships as the `adrafinil` binary, installed at `/usr/local/bin/adrafinil` or `~/.local/bin/adrafinil` on a non-admin install)

### 3.2 Why three tiers (not just app + helper)

- **Helper must be privileged** to call sleep-blocking APIs. It must be small and audited.
- **Daemon runs as user** so it can watch user-owned processes, write logs to `~/Library/Application Support`, and respond to per-user lid notifications. It is always-on (not just when the menu bar app is open) so agents can call `adrafinil acquire` even without the app running.
- **App is user-facing** and may quit/relaunch freely. Keeping state in the daemon means the menu bar app is a pure view layer.

The helper exposes a single mutating endpoint — `setSleepBlocked(Bool)` — plus read-only introspection (`sleepBlockedState`, `version`). The daemon owns all the policy (ref counting, thermal, idle, lid). This keeps the privileged surface trivial to audit.

---

## 4. Sleep-blocking mechanism

`IOPMAssertionCreateWithName` with public assertion types (`kIOPMAssertPreventUserIdleSystemSleep`, etc.) does **not** override clamshell sleep — its own header says "the system may still sleep for lid close", and `caffeinate` confirms it. So two mechanisms compose, both held by the helper:

1. **Idle system sleep** (lid open) — a standard reference-counted `IOPMAssertion` (`kIOPMAssertPreventUserIdleSystemSleep`). The kernel auto-releases it if the helper dies. Visible in `pmset -g assertions`.
2. **Clamshell (lid-closed) sleep** — the global **`SleepDisabled`** power setting, applied by shelling out to **`pmset -a disablesleep 1`**.

> **Empirical note (macOS 26.3, real-device tested).** Three cleaner, in-process mechanisms were each tried and **none keep a displayless lid-closed Mac awake**:
> - Private `RootDomainUserClient` selector 12 (`kPMSetClamshellSleepState` → `setClamShellSleepDisable`) — returns `kIOReturnSuccess`, Mac **still sleeps** (governs the external-display "clamshell mode" path, not no-display lid-close).
> - Public `IORegistryEntrySetCFProperty(IOPMrootDomain, "SleepDisabled", …)` — `kIOReturnNotPermitted` (0xE00002E2) even as root.
> - `IOPMSetSystemPowerSetting("SleepDisabled", CFNumber(1))` — this *is* the per-key call `pmset`'s disablesleep path makes (confirmed by disassembling `/usr/bin/pmset`: `disablesleep` → `CFDictionarySetValue(dict, "SleepDisabled", CFNumber)`; appliers at `0x100008ae4` `IOPMSetPMPreferences` and `0x100008e14` `IOPMSetSystemPowerSetting`). Called alone it returns `kIOReturnSuccess` but `pmset -g` still shows `SleepDisabled 0` and the **Mac sleeps on lid close** — `pmset` coordinates `IOPMSetPMPreferences` + activation around it, which the single call doesn't reproduce.
>
> Only the full `pmset -a disablesleep 1` was verified to keep the Mac awake (lid closed, no external display, on battery): heartbeat continuous across the closed period, vs. a clear sleep gap with it off. It is blunt — global, also suppresses idle sleep, persists in the power-management prefs until cleared — but it is the path that works, and it is Apple's own tested implementation. The call runs only on block-state flips, so the subprocess cost is negligible. Full investigation: `~/Developer/Research/macos-clamshell-sleep-private-api.md`.

`disablesleep` is **not** cleared on crash and can reset across a sleep/wake cycle. So: the helper clears it on release and again on startup (crash recovery), and the daemon re-applies the blocking state on system wake (§6.5).

**Failure mode**: if the helper crashes while sleep is blocked, the daemon detects it (XPC invalidation) and respawns it; on respawn the helper clears any stale `disablesleep` before re-applying the current state. Worst case: a brief window where sleep is allowed. Acceptable.

---

## 5. Detection — how the daemon knows agents are active

### 5.1 Primary: hooks

The daemon does not directly detect agents. The CLI (`adrafinil acquire <session-key> --tool <tool> --reason <reason>`) is called from each agent's hook system. The daemon refcounts by session key.

**Session id resolution.** The hook command passes the session id as a positional arg via a shell env-var expansion (`$CLAUDE_CODE_SESSION_ID`, etc.), but the CLI **prefers the `session_id` field from the JSON the hook receives on stdin** when present. Every Claude-Code-style hook system (Claude Code, Codex, Gemini CLI, Cursor) delivers this JSON, so stdin is the reliable, agent-agnostic source; the env-var arg is a fallback. This avoids the per-agent env-var naming pitfalls that are easy to get wrong (e.g. Claude is `CLAUDE_CODE_SESSION_ID` not `CLAUDE_SESSION_ID`; Codex exposes `CODEX_THREAD_ID` and no `CODEX_SESSION_ID`, and documents only the stdin field).

### 5.2 Tier-1 agents (full hook support, identical install pattern)

These five tools support shell-command hooks with JSON config and `SessionStart` + a session-end-equivalent event. The installer GUI writes to all five:

| Tool | Config path | Start event | End event |
|------|-------------|-------------|-----------|
| Claude Code | `~/.claude/settings.json` | `SessionStart` | `SessionEnd` |
| Codex | `~/.codex/hooks.json` | `SessionStart` (interactive only; see §5.5) | — (process-exit) |
| Cursor | `~/.cursor/hooks.json` | `sessionStart` | `sessionEnd` |
| Gemini CLI | `~/.gemini/settings.json` | `SessionStart` | `SessionEnd` |
| Goose | `~/.agents/plugins/adrafinil/hooks/hooks.json` | `SessionStart` | `SessionEnd` |

Hook entry pattern (Claude/Codex/Gemini/Goose share this shape):

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "adrafinil acquire $CLAUDE_CODE_SESSION_ID --tool claude-code"}]}],
    "SessionEnd":   [{"hooks": [{"type": "command", "command": "adrafinil release $CLAUDE_CODE_SESSION_ID --tool claude-code"}]}]
  }
}
```

Cursor's schema differs (`{"command": "..."}` rather than nested `hooks`). The installer writes the right shape per tool.

### 5.3 Tier-2 agents (partial / non-trivial integration)

| Tool | Strategy |
|------|----------|
| Crush | Only `PreToolUse` exists. Use it to call `adrafinil acquire`; rely on the process-exit watcher for release. Config: `~/.config/crush/crush.json`. |
| Aider | No hooks. Installs a shell alias in `~/.zshrc`/`~/.bashrc` (opt-in) that wraps `aider` with acquire/release. |
| Hermes | Generates a Python plugin at `~/.hermes/plugins/adrafinil/adrafinil.py` that subprocess-calls the CLI. |
| OpenCode | Generates a TypeScript plugin at `~/.config/opencode/plugins/adrafinil.ts`. |
| Cline | Shell-alias wrapper in `~/.zshrc` (SDK plugin would require a user-side TypeScript build). |

### 5.4 Fallback: process sniffing

The daemon maps known agent binary names to their `AgentKind` (`AgentKind.byBinaryName`):

```
claude, codex, cursor, Cursor, gemini, goose, goose-cli,
crush, aider, hermes, opencode, cline
```

A kqueue watcher fires `NOTE_EXIT` on watched PIDs; a periodic sweep (every 30s) catches anything launched between events and re-arms watches. This serves two purposes:

- Force-releases assertions when the owning agent process dies without firing its end hook (Codex `Stop` semantics, crashes).
- Optionally (off by default, toggleable) auto-acquires for sniffed agents that have no hook installed.

### 5.5 Codex special case

Codex's hook model differs from Claude's in three ways that were verified empirically against Codex 0.135.0 on a real device:

1. **No session-end hook.** `Stop` fires per *turn*, not at session end, and there is no session-end event. So Adrafinil installs **only** a `SessionStart` → acquire hook and releases on **process exit** via the §5.4 watcher (keyed by the session id). Installing a `Stop` → release would drop the assertion after the first turn.
2. **Hooks only fire in the interactive TUI — not `codex exec`.** The non-interactive `codex exec` path does not engage the hook runtime at all (no SessionStart, even with `--dangerously-bypass-hook-trust`; the machinery is wired through the TUI/app-server startup path). So **hook-based capture covers interactive Codex only**; for `codex exec`, capture relies on §5.4 process-sniffing (the daemon sees the `codex` process and auto-acquires, with the same process-exit release).
3. **Hook trust.** Codex will not run a command hook until its exact definition is trusted (hash-based), via `/hooks` in the TUI. Adrafinil cannot trust on the user's behalf, so the installer surfaces this: after wiring Codex, the user must open Codex and trust the Adrafinil hook (or it silently won't run).

Codex delivers the session id as `session_id` on the hook's stdin (and `CODEX_THREAD_ID` in the environment); the CLI reads the stdin field (§5.1). Because process-sniffing is the only path that captures *both* interactive and `exec` Codex sessions, it is the recommended capture mode for Codex.

### 5.6 Subagent and resume semantics

`SessionStart` fires on Claude Code/Codex/Cursor resume and clear; subagents fire their own start/end. Reference counting handles both: each acquire is keyed by `(tool, session_key)`, release with the same key is idempotent, duplicate acquires for the same key are no-ops, and releases for unknown keys are warnings, not errors.

---

## 6. Assertion lifecycle and safeties

### 6.1 State

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

actor AssertionRegistry {
    private var assertions: [String: Assertion] = [:]
    var isBlocking: Bool { !assertions.isEmpty }

    // Emits the new value of isBlocking whenever it flips. The daemon iterates
    // this single stream and drives the helper serially, so the helper never
    // sees an out-of-order or stale value.
    nonisolated let blockingStateChanges: AsyncStream<Bool>
}
```

When `isBlocking` flips true the daemon calls the helper `setSleepBlocked(true)`; when it flips false, `setSleepBlocked(false)`.

### 6.2 Idle release

A timer every 60s checks each assertion:

- If the owning PID is gone → release.
- If the owning PID's CPU usage has stayed below threshold for ≥ `idleReleaseMinutes` (default 5, user-configurable) → release.
- If `expiresAt` (TTL) has passed → release.

CPU usage is sampled with `proc_pidinfo(PROC_PIDTASKINFO)`, comparing accumulated user+system CPU time between ticks.

### 6.3 Thermal cutout

While the lid is closed AND at least one assertion is held, the daemon polls the SMC every 15s:

- Sensor: `TC0P` (CPU proximity).
- Threshold: 80°C default (configurable, 70–95°C).
- On crossing: release **all** assertions, log a `thermalCutout` event, set the helper to allow sleep, and record a "thermal cutout" entry for the lid-open summary.

SMC access opens the `AppleSMC` IOService and issues a keyed read (`KERNEL_INDEX_SMC`). Public API, no entitlements required.

### 6.4 Lid-close audio cue

Lid-state changes are observed via IORegistry notifications on the `AppleClamshellState` property.

When the lid transitions open → closed AND `isBlocking == true`:
- Play a short, synthesized two-tone descending chime (G5 → D5, ~0.4s) so it's recognizably intentional rather than a system error sound. The tones are generated at runtime — there is no bundled audio file.
- Respect system volume; do not unmute. If muted, skip (the user gets the lid-open summary instead). The user can alternatively pick a built-in macOS system sound.

When the lid transitions closed → open AND any assertion was held during the closed period:
- Show the lid-open summary (§7.3).

### 6.5 Wake re-assertion

The private clamshell-disable bit (§4) can be reset by the kernel across a sleep/wake cycle. The daemon registers for system power notifications (`IORegisterForSystemPower`) and, on `kIOMessageSystemHasPoweredOn`, re-pushes the current blocking state to the helper so it re-applies the bit. The helper's `set` is idempotent and re-asserts the clamshell bit on every blocking call, so this is a no-op when nothing was lost and a repair when it was.

---

## 7. UX

### 7.1 Menu bar status item

Icon states:

- **Idle** (no assertions): grayscale outlined moon icon.
- **Active** (≥1 assertion): filled colored sun icon, optionally badged with the assertion count.
- **Thermal cutout** (last 30s after trigger): red exclamation, reverts to idle after 30s.

Click → popover:

```
Adrafinil

▌ 2 agents active — staying awake

  Claude Code · 12m · "Refactoring auth module"
  Cursor · 4m · "Running tests"

  [Force sleep now]  [Settings…]

  Lid: open · CPU temp: 58°C
```

### 7.2 Settings window

Tabs: **General**, **Agents**, **Safety**, **About**.

- **General**: launch at login, show in menu bar, sound on lid close (on/off + volume + sound picker), idle release minutes.
- **Agents**: detected agents with a per-agent toggle. Each row shows install state (✓ installed / ✗ not installed / ⚠ modified externally) and a link to reveal the hook config in Finder.
- **Safety**: thermal threshold slider (70–95°C, default 80), thermal cutout toggle, idle release toggle + minutes, process-sniffing toggle + auto-acquire-for-known-agents toggle.
- **About**: version, GitHub link, license, credits, "uninstall and quit".

### 7.3 Lid-open summary

A brief panel appears top-right when the lid opens after a closed-with-assertions period:

```
While you were away:
  ✓ Claude Code finished (4m 12s)
  ✓ Cursor finished (2m 8s)
  Peak CPU temp: 67°C
  [Dismiss]
```

Auto-dismisses after 8s.

### 7.4 First-run installer flow

1. Launch → "Adrafinil needs to install a privileged helper to block system sleep. This is open source and audited. [Continue]"
2. SMAppService approval prompt (system-handled). User confirms in System Settings → Login Items.
3. "Daemon installed. Let's wire Adrafinil into your AI agents."
4. Auto-detected agents shown as a checklist (only checked agents installed; user can preview the diff per agent).
5. Click "Install" → writes configs, sets up wrapper scripts where needed, adds the CLI to PATH.
6. "Done. Adrafinil lives in your menu bar."

No privileged work happens before the user proceeds — helper/daemon registration, the CLI symlink, and hook installation are each triggered by explicit buttons.

---

## 8. CLI

Single binary, subcommand-style:

```
adrafinil acquire <session-key> [--tool <name>] [--reason <text>] [--ttl <seconds>]
adrafinil release <session-key>
adrafinil status [--json]
adrafinil install-hooks [--tool <name>] [--dry-run]
adrafinil uninstall-hooks [--tool <name>]
adrafinil daemon-status
adrafinil version
```

### Behavior

- `acquire` connects to the daemon socket, sends the request, exits (<50ms target). If the daemon is not running, it prints a warning and exits 0 (don't fail the agent). `--ttl` is a hard deadline after which the daemon auto-releases even without a `release` call.
- `release` is idempotent. Unknown keys: warning, exit 0.
- `status --json` prints current assertions, daemon health, helper health, lid state, and temperature.
- `install-hooks` / `uninstall-hooks` mirror the GUI installer (so the CLI alone is enough for headless setups). `--dry-run` prints diffs without writing.

### Wire protocol

Length-prefixed JSON over a Unix socket at `~/Library/Application Support/Adrafinil/cli.sock`.

```json
// request
{"op": "acquire", "key": "claude-code:abc123", "tool": "claude-code", "reason": "session", "pid": 12345, "ttl": null}
// response
{"ok": true, "blockingState": true, "assertionCount": 1}
```

---

## 9. Persistence

`~/Library/Application Support/Adrafinil/`:
- `config.json` — user settings.
- `cli.sock` — daemon socket.
- `state.json` — current assertions (so the daemon can resume after a crash without losing live agent sessions).
- `events.log` — append-only JSON-lines event log (acquire, release, thermal cutout, lid close/open). Rotated at 10MB to `events.log.1`. Feeds the "While you were away" summary.

---

## 10. Distribution (planned)

Not yet implemented — the project currently builds and runs from Xcode. The intended distribution model:

- **Primary**: signed + notarized DMG on GitHub Releases.
- **Homebrew cask**: `brew install --cask adrafinil`.
- **Auto-update**: Sparkle 2 with EdDSA signatures, appcast on GitHub Pages.
- **Build**: GitHub Actions workflow on tag push → build → notarize → release.
- **Signing**: Developer ID Application + Developer ID Installer.

The privileged helper is bundled inside the app and installed via `SMAppService.daemon(plistName:)`. The CLI ships in `Contents/Helpers/adrafinil` — not `Contents/MacOS`, where a lowercase `adrafinil` collides case-insensitively with the `Adrafinil` app binary — and is symlinked to `/usr/local/bin/adrafinil` (or `~/.local/bin/adrafinil` if non-admin) on first run, with user consent.

---

## 11. Open questions / research items

1. **Wake-reset behavior of the clamshell bit** is not empirically pinned down — §6.5 re-asserts defensively on every wake. Worth confirming with a real sleep/wake test whether the bit actually survives wake (and whether the unprivileged path takes effect, or only the root helper's does).
2. **Codex `SessionEnd`**: if Codex ships a real session-end event, §5.5 can drop the process-exit dependency.
3. **Hook latency under load**: the <50ms target is met by design (thin socket protocol, static lookups), but hasn't been measured across all agents. If an agent's hook runner is slow, a fire-and-forget invocation may be needed — at the risk of the hook system killing backgrounded processes.
4. **Crush `PreToolUse`-only**: when Crush ships `SessionStart`/`End`, move from process-watch release to hook-based release.

---

## 12. Naming

**Adrafinil** — a eugeroic prodrug to modafinil, fitting the existing nootropic-app theme (Dantrolene, Harmaline, Carbidopa). Less well-known than Modafinil itself, which is the point — searchable, ownable, distinctive.

---

*Describes Adrafinil v0.1, as built.*
