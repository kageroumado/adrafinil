# Security Policy

Adrafinil ships a **root LaunchDaemon** (`AdrafinilHelper`) — the one component that can change
system sleep behavior. We take its surface seriously and welcome reports.

## Reporting a vulnerability

Please report security issues **privately**, not as public GitHub issues:

- Use GitHub's [private vulnerability reporting](https://github.com/kageroumado/adrafinil/security/advisories/new)
  (Security → Advisories → "Report a vulnerability"), or
- Reach out to [@kageroumado](https://x.com/kageroumado).

Please include a description, affected version, and reproduction steps. We aim to acknowledge within
a few days. Once a fix ships, we're happy to credit you (or keep you anonymous — your call).

## Scope — what matters most

The privileged surface is intentionally tiny. The highest-value targets:

- **`AdrafinilHelper` (root LaunchDaemon).** Its mutating surface is block/unblock plus renewal and
  clearing of a short sleep-block lease, with read-only state/version. It holds no policy. Every
  incoming XPC peer is checked by
  `CallerVerifier` (`AdrafinilShared/Sources/AdrafinilShared/IPC/CallerVerifier.swift`): the caller
  must be a signed Adrafinil component sharing our Team Identifier. Bypasses of that check, or any way
  to drive `pmset disablesleep` from an unauthorized caller, are the most serious class of bug.
- **`AdrafinilDaemon` (LaunchAgent, runs as your user).** Holds the assertion registry and all policy.
  Its CLI socket lives at `~/Library/Application Support/Adrafinil/cli.sock` (mode `0600`).
- **The `adrafinil` CLI.** Reachable from agent hooks; takes a session key and tool name.

A failure that leaves the Mac **permanently awake** (a leaked `pmset disablesleep 1`) is treated as a
security-relevant bug, not just a nuisance — the helper resets `disablesleep` to `0` on every respawn
specifically to bound that risk.

Every successful block starts a 15-second lease renewed by the daemon every five seconds; expiry
clears the block. Missing lease capability or a renewal failure leaves normal sleep enabled rather
than risking a permanent wake lock.

## Supported versions

Only the latest release and `main` receive fixes.
