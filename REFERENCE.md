# adrafinil reference

[Overview](README.md)

## How it works

Agents don't talk to Adrafinil directly. Each agent's hook system calls the bundled CLI:

```sh
adrafinil acquire <session-key> --tool claude-code --reason "long build"   # when a turn starts
adrafinil release <session-key>                                            # when the agent goes idle
```

Holds are **activity-scoped**, not session-scoped: Claude Code acquires on `UserPromptSubmit` and
releases on `Stop`, so the Mac is only kept awake while the agent is actually working — an
open-but-idle session at the prompt lets it sleep normally.

The daemon refcounts by session key and asks the helper to block sleep while the count is non-zero.

An agent can also keep the Mac awake for a background task that outlives its reply (a long build or
deploy) with a time-boxed **hold** — either by calling `adrafinil hold` directly or, for MCP-capable
agents, through the bundled MCP tool that `adrafinil mcp` serves:

```sh
adrafinil hold --for 30m --reason "deploy"   # keep awake up to 30 min, then auto-release
adrafinil mcp                                 # speak the Model Context Protocol on stdio (for agents)
```

You don't need an agent at all: the menu bar's **Keep awake** button places the same kind of
time-boxed hold by hand — for a long download or any off-agent task — and **Let it sleep** releases
everything. So Adrafinil covers all three: it auto-detects agent activity through hooks, lets agents
drive it explicitly over MCP/CLI, and can be flipped on manually when you need it.

Other subcommands: `status`, `install-hooks`, `uninstall-hooks`, `daemon-status`, `version`.

### Claude Code profiles (`CLAUDE_CONFIG_DIR`)

A Claude Code profile run with its own `CLAUDE_CONFIG_DIR` (say an alias for a second account) reads
its settings from that directory, not `~/.claude`. Install the hooks there, plus the MCP server with
`--mcp`:

```sh
adrafinil install-hooks --config-dir ~/.claude-work --mcp
adrafinil uninstall-hooks --config-dir ~/.claude-work --mcp
```

The hooks report the profile's directory on each `acquire`, so waiting detection also reads that
profile's `sessions/` — no extra setup. Only directories inside your home folder are accepted, up to
eight profiles at a time.

### Add your own agent

Adrafinil ships integrations for the common agents, but the CLI works for **any** tool — the daemon
accepts an arbitrary `--tool` label from any same-user caller, so nothing needs to change to wire up
one Adrafinil has never heard of. Settings → **Agents** → *Add your own agent* generates the exact
snippets from a name you type; pick the shape that matches your agent:

- **It has hooks / events** — add `acquire` on start and `release` on stop, keyed on your agent's
  session id so each turn brackets cleanly:

  ```sh
  adrafinil acquire "$SESSION_ID" --tool my-agent   # on start / prompt submit
  adrafinil release "$SESSION_ID" --tool my-agent   # on stop / finish
  ```

- **It has no hooks** — wrap the command so the hold spans the whole run (keyed on the shell's `$$`),
  or drop a single timed hold for a background job:

  ```sh
  adrafinil acquire $$ --tool my-agent && my-agent "$@"; adrafinil release $$ --tool my-agent
  adrafinil hold --for 2h --pid $$ --reason "my-agent session"
  ```

Custom agents aren't auto-detected or process-watched, so pair every `acquire` with a reliable
`release` — the idle-release timeout and each hold's time limit are the safety net if one is missed.

## Quirks worth knowing

- **Public IOPM assertions don't beat clamshell sleep.** `IOPMAssertionCreateWithName` with the public types (and therefore `caffeinate`) will not keep a lid-closed Mac awake. Adrafinil's v1 uses `pmset disablesleep 1`, which is blunt (it also disables idle sleep) and *must* be cleared on shutdown or it leaks — the helper resets to `disablesleep 0` on respawn before re-applying state.
- **Daemon handlers run on arbitrary queues.** XPC and socket callbacks can arrive on any dispatch queue, so the assertion registry and shared state are synchronized accordingly. Tread carefully around concurrency when modifying the daemon.
- **The CLI is on a latency budget.** `acquire`/`release` are in the hot path of every agent session, hence static lookups (e.g. `AgentKind.allBinaryNames`) and a thin socket protocol instead of full XPC for the CLI ↔ daemon hop.

## Development notes

- Set one development team for the app, daemon, and helper; the caller check reads that signing team at runtime. Shared logic tests live in `AdrafinilShared`.
