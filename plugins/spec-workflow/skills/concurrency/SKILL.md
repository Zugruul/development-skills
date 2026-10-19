---
name: concurrency
description: Shows or sets how many tasks the build loop works on at once (methodology.maxInProgress) — this one number is both the board's WIP limit and the number of parallel implementation lanes. Use when the user asks how many tasks run at once, wants parallel lanes, or wants strictly-sequential building back. With no argument, show the current value and ask.
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

The user can type any other positive integer via Other. Apply with `concurrency.sh set <choice>` — this surgically edits `methodology.maxInProgress` in `.neural-network/project.yaml`, a versioned project-wide change; remind the user to commit it. If they pick N>1, note the trade-off: parallel lanes need NON-overlapping tasks (overlap → conflicts), and any merge makes the other lanes rebase — see the concurrency reference.

`methodology.serialDelivery` (#272/#423) combines with `maxInProgress` into ONE coherent mode rather than a separate, purely-stricter knob: a task occupies a COUNT-based slot from PICK until MERGE (both *In progress* and *In review* count toward `maxInProgress` — no slot ids, the board is the sole state). `next` allows a new PICK while `occupied < maxInProgress`, so `maxInProgress: N>1` still gives N genuinely parallel implementation lanes; once every slot is occupied, an In-progress task is always the actionable next step (`RESUME`), and only when EVERY occupying task is In review (nothing left to resume) does it print `WAIT` so the loop runs the **merge dance** — merges themselves still serialize strictly ONE at a time, FIFO by In-review entry oldest-first, guarded by a merge-dance lock (full protocol: `../../skills/build-next/references/concurrency.md`). At `maxInProgress: 1` this collapses to the original #272 rule (no NEW task while the single slot is occupied at all). `guard-board-move.sh` enforces the same slot-count rule as defense in depth against a manual `board.sh move <n> "In progress"`.

### WIP admission at board mutations

`board.sh` enforces WIP admission at direct and replayed status mutations. It counts every item in the active board's work status (`statusFlow[1]`, or the sole status), plus review (`statusFlow[2]`) when `serialDelivery` is true; `maxInProgress` defaults to 1 and must be a positive integer, and `serialDelivery` defaults to false and must be boolean. A task already occupying either counted status may resume or move between counted statuses without adding a slot, even on an over-limit board. Entry into review directly also requires capacity in serial mode. The command reads a fresh complete board snapshot, validates one target identity, and serializes admission across cooperating processes and linked worktrees of this clone. Capacity or invalid-state refusals do not newly queue direct starts; blocked queued starts remain recoverable and are checked again on replay. Proven rate limits still defer through the existing queue. Existing checkpoint, comments, gate, review and closure guards remain required.

The picker reports capacity before work begins; mutation admission makes the final decision. The unchanged Claude hook is additional offline defense in depth; `SERIAL_DELIVERY_OVERRIDE=1` overrides only that hook, never command admission. There is no slot ledger or distributed reservation: other clones, raw API writes and eventual consistency of GitHub reads can still exceed the limit. See the plugin README's WIP admission recovery instructions for a busy or interrupted local mutex.
