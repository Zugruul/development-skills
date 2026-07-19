---
name: seed-board
description: Seeds the GitHub Project board from a spec's backlog — complexity-scores every task (splitting any 8+ before it enters the board), then idempotently creates issues + board items with status/priority/estimate. Use after setup-project, or when a new spec or new tasks are added to the backlog.
allowed-tools: Bash
---

# Seed the board from the backlog

Pre-start check — run this now, before anything else: `bash "../../scripts/preflight.sh" --spec`. If it prints `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

## 1. Build the task file
From the spec's backlog doc (`specs[].backlogPath` in `.claude/project.yaml`), write one line per task to a temp file (`#` comments and blank lines allowed):
```
<task-id>|<priority>|<points>|<epic-id>|<title>
CP-001|P0|5|E0|Repo scaffold: pnpm workspace + tsconfig
CP-010|P1|8|E1|http-kit vendored (Fastify + route-spec)
```
Rules — check each line before running:
- `task-id` = `<taskPrefix>-<number>`; the prefix must match a `specs[].taskPrefix` and the number must fall inside one of that spec's `epics[].taskRanges` (otherwise `board.sh next` can't sequence it).
- `priority` must be a priority option name; `epic-id` must be that spec's epic id.
- Titles must not contain `|`.
- Multiple specs may be mixed in one file.

## 2. Complexity gate — score, then split before seeding
Score every line 1–10: +2 each for touching >2 packages/components · a new external boundary (API/DB/queue/process) · security/isolation/money surface · significant unknowns (no similar code exists yet) · heavy test burden (integration/e2e infra). 1–3 trivial, 4–7 normal, **8+ = too big to enter WIP as one unit**.
For every 8+ task: split it into 2–4 tasks inside the same epic's number range (headroom exists by design), each independently testable, ordered so earlier ones unblock later ones. Update the backlog doc to match, then re-check the new lines (a split part can still score 8+ — split again). Story points must roughly track the score; a 3-point task scoring 9 means the estimate is wrong too.

## 3. Run the seeder
```bash
bash "../../scripts/seed-board.sh" /path/to/tasks.txt
```
Idempotent: existing issues (matched by exact `"<task-id>: <title>"`) are skipped; fields are (re)applied. Watch for `!!`/`!` lines — each names the task and the failing step; fix and re-run.

## 4. Verify
```bash
bash "../../scripts/board.sh" list | sort
bash "../../scripts/board.sh" next
```
Every seeded task should appear in the first status with its priority, and `next` should pick the expected first task.
