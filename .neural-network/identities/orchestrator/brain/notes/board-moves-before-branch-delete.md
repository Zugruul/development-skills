---
tags: [board, guards, work-type-local, merge]
paths: ["plugins/spec-workflow/scripts/guard-board-move.sh", "plugins/spec-workflow/scripts/board.sh"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255 close
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Under work.type: local + squash merge, guard-board-move's red-first check reads the CURRENT branch's commit history — the squash tip on main has no test-only commit, so 'In review'/'QA' moves fail from a detached-at-merge checkout. Order of operations at task close: run the gate and ALL board moves (In review → QA) while still on the task branch, and only then delete it (or recreate it from the pre-merge tip if already deleted). Also: the gate hook fires PRE-execution, so `gate.sh && board.sh move` in one command is always blocked — run them as separate calls; and board.sh comment reads its body from stdin (--body-file -), an argument body hangs forever.

Related: [[merge-via-temp-worktree-when-main-held]]
