---
name: next-task
description: Picks the next task from the board honoring priority order, epic sequencing, dependency guards, and the WIP limit, and reads the issue's human comments before committing to it. Use at the start of each build iteration or for 'what should I work on next'.
allowed-tools: Bash
---

# Pick the next task

Pre-start check — run this now, before anything else: `bash "../../scripts/preflight.sh" --spec`. If it prints `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

```bash
bash "../../scripts/board.sh" next          # or: next <spec-id> to restrict to one spec
```
The script already applies priority order, epic sequencing, `blockedBy` guards, and the work-in-progress limit from `.claude/project.yaml`. It prints one of:
- `=> PICK: #N` (+ any `BLOCKED` items with the reason) — proceed with #N;
- `=> RESUME: #N` — work is already in progress at the WIP limit: do NOT start anything new; resume #N (its branch exists) and finish it to at least *In review* first.

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
