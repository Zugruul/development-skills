---
name: concurrency
description: Shows or sets how many tasks the build loop works concurrently (methodology.maxInProgress — the board WIP limit AND the number of parallel implementation lanes). Use when the user asks how many tasks run at once, wants parallel lanes, or wants strictly-sequential building back. With no argument, show the current value and ask.
allowed-tools: Bash, AskUserQuestion
---

# Concurrency — show / set

`concurrency.sh` = `bash "../../scripts/concurrency.sh"`.

`methodology.maxInProgress` is THE concurrency knob: the board WIP limit AND the number of parallel implementation **lanes** (each lane = its own git worktree + branch + dev agent). `1` (default) = strictly sequential. Lane rules: `../../skills/build-next/references/concurrency.md`.

**Invoked with an argument** (`status` / `set <n>`): run `concurrency.sh <args>` and report the output verbatim.

**Invoked with NO argument**: run `concurrency.sh status` for the current value, then ask through the host's structured-input facility (single question, header "Concurrency", current value noted in the question). (On Claude Code, this is the AskUserQuestion tool.) Options:

- **1 — sequential (Recommended)** — description: "One task at a time. Simplest and safest; no lane coordination. The default."
- **2** — description: "Up to 2 tasks in parallel lanes — only worthwhile when ready tasks don't overlap (different epics/packages)."
- **3** — description: "Up to 3 parallel lanes. More throughput, more rebase churn — every merge forces the other lanes to rebase."

The user can type any other positive integer via Other. Apply with `concurrency.sh set <choice>` — this surgically edits `methodology.maxInProgress` in `.claude/project.yaml`, a versioned project-wide change; remind the user to commit it. If they pick N>1, note the trade-off: parallel lanes need NON-overlapping tasks (overlap → conflicts), and any merge makes the other lanes rebase — see the concurrency reference.

`methodology.serialDelivery` (#272) is a separate, stricter knob: even at `maxInProgress: 1`, a task normally leaves the loop's hands at *In review* and the next pick can start while it's still an open, unmerged PR. With `serialDelivery: true`, `next`/`board.sh move <n> "In progress"` refuse to pick a NEW task while any board task is In progress or In review — resuming an already-In-progress task is still allowed (that's finishing, not picking); an In-review task clears only by merging. Gates on the actual merge, not just on lane width. The two knobs are orthogonal: `maxInProgress` caps how many lanes run at once, `serialDelivery` caps how far ahead of the last merge the loop is allowed to get.
