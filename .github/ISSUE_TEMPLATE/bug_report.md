---
name: Bug report
about: Report a problem with Adrafinil (Mac won't sleep, sleeps mid-work, a hook not firing, etc.)
title: ""
labels: ""
assignees: kageroumado
---

## Summary

<!-- One or two sentences: what happens, and when. e.g. "Mac sleeps while a background sub-agent is still running" or "Mac stays awake after the agent finished". -->

## Environment

- **Adrafinil**: <!-- e.g. 1.4.0 (menu bar → About, or the GitHub Release) -->
- **macOS**: <!-- e.g. 26.1 (Build 25B?) -->
- **Hardware**: <!-- e.g. M4 MacBook Air; on battery / on AC; lid open / clamshell -->
- **Agent(s)**: <!-- which agent hooks are connected — Claude Code / Codex / Cursor / Gemini / Aider / a custom "Add your own agent" — and its version -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What you expected — e.g. "stays awake until the background task finishes" or "lets the Mac sleep once the agent is idle". -->

## Actual behavior

<!-- What actually happened. -->

## State (optional but helpful)

After reproducing, capture:

- **`adrafinil status`** — shows the active holds/assertions and whether the daemon helper is connected:

  ```sh
  adrafinil status
  ```

- **Which hooks are installed** — Settings → Agents in the app, or the agent's own config:
  - Claude Code: `~/.claude/settings.json`
  - Codex: `~/.codex/hooks.json` (must be trusted via `/hooks`)

## Log excerpt

Adrafinil logs to the unified log. Capture the window around the problem:

```sh
log show --last 15m --predicate 'subsystem BEGINSWITH "glass.kagerou.adrafinil"' --style compact
```

This records hold acquire/release (per-turn, sub-agent, background-shell), idle-release, TTL/dead-process reaping, and cutouts.

## Recovery note

If the Mac won't sleep and you need it to now, **quit Adrafinil from the menu bar** — that drops every hold. If hooks seem to have drifted, reconnect the agent in **Settings → Agents** (re-installs its hooks); for Codex, re-trust them with `/hooks`.
