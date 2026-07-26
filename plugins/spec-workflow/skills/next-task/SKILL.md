---
name: next-task
description: Picks the next task from the board, honoring priority order, epic sequencing, dependency guards, and the WIP limit, and reads the issue's human comments before committing to it. Use at the start of each build iteration or for 'what should I work on next'.
allowed-tools: Bash
---

# Pick the next task

Pre-start check — run this now, before anything else: `bash "../../scripts/preflight.sh" --spec`. If it prints `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

```bash
bash "../../scripts/board.sh" next          # or: next <spec-id> to restrict to one spec
```
The script already applies priority order, epic sequencing, `blockedBy` guards, and the work-in-progress limit from `.claude/project.yaml`. It prints one of:
- `=> PICK: #N` (+ any `BLOCKED` items with the reason) — proceed with #N;
- `=> RESUME: #N` — the WIP limit is reached (no headroom to start anything new): under plain `maxInProgress`, that means WIP is at/over the limit; under `methodology.serialDelivery` (#423), it means a **slot** is occupied — `occupied = count(In progress) + count(In review) >= maxInProgress` — and at least one of the occupying tasks is *In progress* (finishing/resuming it is always the actionable next step, even though its slot only frees at merge, not at *In review*). Do NOT start anything new: resume #N (its branch exists) and finish it to at least *In review* first.
- `WAIT: merge-dance — #a,#b In review; slots N/N occupied — run the dance (merge oldest first) to free a slot` — only under `methodology.serialDelivery`, when every occupying task is *In review* (no In-progress task exists to resume — only a merge frees a slot). This is the **merge dance**: run it FIFO, oldest In-review task first (the numbers are already listed oldest-first). For the FIRST named issue: check its PR's merge state (`gh pr view <branch-or-number> --json state,mergedAt`, or `gh pr list --search "..."` if the PR number isn't in hand). If it's merged already, move the item to *QA* (folding its spec-delta per the existing rule) and re-run `next` — the WAIT should clear or shrink. If it's still open, this is where the actual dance protocol applies — rebase it onto current main, re-gate, squash-merge, board → QA (full protocol: `build-next/references/concurrency.md`) — before moving to the next-oldest name in the list. If a human/reviewer merge is what's pending (not something this session can do), report the blocker on the issue/handoff and idle/heartbeat rather than looping tight.
- **A `Merge queue (In review, oldest-first by issue number): ...` block above any of the three lines** — printed whenever `serialDelivery` is on and anything is *In review*, REGARDLESS of whether the decision is PICK/RESUME/WAIT. It is informational under PICK/RESUME (headroom exists, or an In-progress lane is the priority — but the dance queue is still there, waiting) and is exactly what a WAIT is telling you to work through.

## Then, before committing to the pick (mandatory)
1. `bash "../../scripts/board.sh" show N` — read the body **and every comment**. Humans post steering, scope changes, and answers there.
2. If comments change acceptance criteria or implementation details:
   - Write the updated body to a temp file and apply it: `board.sh edit-body N <file>` (keep the original structure; fold the comment's decisions into the criteria).
   - Reply so the human knows it was seen: `printf '%s' "Applied: <one-line summary of what changed>" | board.sh comment N`.
3. If a comment asks a question you cannot answer or blocks the task (needs credentials, a human decision), reply with your best analysis via `comment`, skip this task, and take the next candidate from the list instead.

## Output
Report the chosen `#N` and why (priority + epic + any comment-driven changes). Hand off to the `implement-task` skill.

## No work left?
If `next` prints `(backlog empty)` or only BLOCKED items remain, stop the loop and write a handoff (see the `handoff` skill).
