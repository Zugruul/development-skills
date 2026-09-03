---
tags: [concurrency, testing, gate]
paths: ["plugins/spec-workflow/scripts/gate.sh", "plugins/spec-workflow/tests/**"]
strength: 1
source: "MEM-031/#218 same-session retro, 2026-07-18"
graduated: false
created: 2026-07-18
---

Running more than one full `gate.sh`/`run-tests.sh` invocation concurrently against this repo — even from separate worktrees — causes spurious mass test failures (observed: several runs in one session logged 37 FAILED tests each in .claude/lessons.jsonl, all during a window where multiple gate processes were live at once). Root cause: some tests bind shared host-level resources (ui-hub's fixed port 4747, filesystem-based board-queue lock dirs) that aren't worktree-scoped. Always serialize gate runs across the whole session — track PIDs and wait for one to fully exit before starting another, regardless of which branch/worktree it's running against.

Related: [[explicit-cd-every-command]]
