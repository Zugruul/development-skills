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
- `=> RESUME: #N` — work is already in progress at the WIP limit (or, under `methodology.serialDelivery`, simply already in progress at all): do NOT start anything new; resume #N (its branch exists) and finish it to at least *In review* first. A trailing `NOTE:` line under `serialDelivery` names an already-In-review item too — nothing to do about it right now, just don't forget it's also waiting on a merge.
- `WAIT: serial delivery — #N ... is In review; ...` — only under `methodology.serialDelivery`, when #N is In review and NOTHING is In progress (so there's nothing to resume — only merging #N unblocks the next pick). Do not start new work. Check the named issue's PR merge state: `gh pr view <branch-or-number> --json state,mergedAt` (or `gh pr list --search "..."` if the PR number isn't in hand). If it's merged, move the item to *QA* (folding its spec-delta per the existing rule) and re-run `next` — the WAIT should clear. If it's still open, this is a genuine wait on a human/reviewer merge: report the blocker on the issue/handoff and idle/heartbeat rather than looping tight.

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
