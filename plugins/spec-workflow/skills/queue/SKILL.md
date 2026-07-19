---
name: queue
description: Enumerates the tasks the autonomous build loop will pick up next, priority-first, and presents them human-readably. Use for 'what's next', 'what will build-next pick up', 'show the task queue', or 'what's upcoming'.
allowed-tools: Bash
---

# Show the build queue

**This skill is READ-ONLY.** Like `next-task`, no board mutation is ever made here — no `move`, `prio`, `edit-body`, `comment`, or any other write to the board. The `=> PICK`/`=> RESUME` line below is informational here, not a decision to start work; committing to a task is `next-task`'s job.

Pre-start check — run this now, before anything else: `bash "../../scripts/preflight.sh" --spec`. If it prints `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

## 1. Get the prioritized + sequenced candidate list
```bash
bash "../../scripts/board.sh" next          # or: next <spec-id> to restrict to one spec
```
This prints, in pick order, up to 5 candidates, any `BLOCKED` items with their reason, and the `=> PICK: #N` / `=> RESUME: #N` decision line — the same priority order, epic sequencing, `blockedBy` guards, and WIP-limit logic `next-task` uses.

## 2. Enrich the top candidates
For each of the top ~5 candidates, run:
```bash
bash "../../scripts/board.sh" show N
```
to pull the issue body (for a one-line gist of what the task is — pull from the acceptance/description line) alongside what `next` already gave you (priority, title). Estimate and epic come from the same `show`/`next` output; if the board tracks estimate as a field, include it, otherwise omit that column rather than guessing.

## 3. Render the queue
Present a compact markdown table, in pick order, with priority visually prominent (e.g. bold or a `P0`/`P1`-style tag):

| # | Issue | Task | Priority | Estimate | Epic | Gist |
|---|---|---|---|---|---|---|
| 1 | #N | SW-NNN — title | **P0** | 3 | Epic name | one-line summary from the issue body |

Follow the table with a separate **Blocked** section listing each `BLOCKED` item from step 1 and its stated reason, verbatim or lightly paraphrased — never drop the reason.

Finally, add a short note explaining the decision line:
- `=> PICK: #N` means #N is the next task the loop will start when nothing is already in progress.
- `=> RESUME: #N` means the board is already at the WIP limit — that in-progress task continues first, before anything new is picked.

## 4. Steering note
Tell the human they can steer this queue by commenting on an issue (fold into acceptance criteria, seen by `next-task`) or by changing an issue's Priority field on the board — either changes what `queue`/`next-task` picks on the next run.

## No candidates?
If `next` prints `(backlog empty)` or only `BLOCKED` items remain, say so plainly — there is nothing queued.
