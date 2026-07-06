<!-- Thanks for contributing to Adrafinil! Fill in what's relevant; delete what isn't. -->

## Summary

<!-- One or two sentences: what this changes, and why. -->

## Related issue(s)

<!-- e.g. "Fixes #12" or "Relates to #12". Delete if none. -->

## Changes

<!-- Bullet the key changes. Keep it skimmable. -->

-

## How it was tested

<!-- Adrafinil is a menu-bar app + LaunchAgent daemon + root helper + CLI driven by agent hooks, so say what you actually exercised — not just that it builds. -->

- **macOS / hardware**:
- **Agent(s) exercised**: <!-- Claude Code / Codex / a custom "Add your own agent" — and how you drove it -->
- **Checks run**:
  - [ ] `swift test` (from `AdrafinilShared/`)
  - [ ] `xcodebuild -scheme Adrafinil -destination 'platform=macOS' build`
  - [ ] `swiftformat --lint .`
- **Behavior observed**: <!-- e.g. `adrafinil status` showed the hold acquired/released as expected; the Mac slept / stayed awake correctly -->

<!-- Useful when a hold behaves unexpectedly:
     log show --last 15m --predicate 'subsystem BEGINSWITH "glass.kagerou.adrafinil"' --style compact -->

## Risk / regressions

<!-- What could this break? Anything touching the hold lifecycle, the privileged helper, or hook install/uninstall deserves a callout. -->

## Checklist

- [ ] `swift test` passes
- [ ] `swiftformat --lint .` passes (the `.githooks/pre-commit` hook formats staged Swift for you — enable with `git config core.hooksPath .githooks`)
- [ ] App builds
- [ ] No unrelated changes bundled in

---

## Authorship

<!-- These PRs are usually written by an agent — record who wrote it and how. -->

- **Agent**: <!-- the agent's name (e.g. Sora), or the human author -->
- **Model**: <!-- the model the agent runs on, e.g. Opus 4.8 (1M context) — leave blank if human-authored -->
- **Session**: <!-- "attended" (a human participated / reviewed live) or "automatic" (unattended agent run) -->
