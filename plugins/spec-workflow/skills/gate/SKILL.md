---
name: gate
description: Runs the project's quality gate via gate.sh — the pass a hook requires before any task can move to In review, and the source of truth for whether the build is green. Use for 'run the gate', 'is it green', and always before review or merge — green is mandatory and enforced.
---

# Quality gate — run gate.sh before review or merge

Run the gate through the wrapper — it executes `commands.gate` from `.neural-network/project.yaml` AND records the pass:

```bash
bash "../../scripts/gate.sh"
```

## Rules
- **Green is mandatory and enforced**: a plugin hook blocks `board.sh move <n> "In review"` unless a recorded pass matches the current tree (any edit after the pass invalidates it). Running the gate command directly does not record a pass — always use `gate.sh`. The recorded pass is per worktree: run `gate.sh` in the lane's own worktree and move the card from there (the hook judges the tree the session's cwd is in, or the tree of an explicit leading `cd <worktree> &&`). Another lane's gate, green or red, never replaces it. A red gate never advances; fix or report the blocker.
- **TDD:** the failing test must be committed *before* the implementation.
- If `methodology.isolationSuite` is set, changes touching protected resources must add cases there — treat missing coverage as a gate failure.
- Fix lint properly; never disable rules to pass (exceptions only where the repo's CLAUDE.md documents them).

## Fast inner loop
While iterating, use `commands.gateFast` from config if set (e.g. per-package watch tests). Always run the full gate before *In review*.
