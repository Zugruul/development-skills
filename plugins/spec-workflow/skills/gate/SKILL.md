---
name: gate
description: Runs the project quality gate via gate.sh, which records the pass a hook requires before any task can move to In review. Use for 'run the gate', 'is it green', and always before review or merge — green is mandatory and enforced.
---

# Quality gate

Run the gate through the wrapper — it executes `commands.gate` from `.claude/project.yaml` AND records the pass:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh"
```

## Rules
- **Green is mandatory and enforced**: a plugin hook blocks `board.sh move <n> "In review"` unless a recorded pass matches the current tree (any edit after the pass invalidates it). Running the gate command directly does not record a pass — always use `gate.sh`. A red gate never advances; fix or report the blocker.
- **TDD:** the failing test must be committed *before* the implementation.
- If `methodology.isolationSuite` is set, changes touching protected resources must add cases there — treat missing coverage as a gate failure.
- Fix lint properly; never disable rules to pass (exceptions only where the repo's CLAUDE.md documents them).

## Fast inner loop
While iterating, use `commands.gateFast` from config if set (e.g. per-package watch tests). Always run the full gate before *In review*.
