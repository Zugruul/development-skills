---
tags: [worktree, board, gate, bug]
paths: ["plugins/spec-workflow/scripts/guard-board-move.sh"]
strength: 1
source: "PRV-001 build-next iteration, live-encountered"
graduated: false
created: 2026-07-15
---

guard-board-move.sh resolves the repo root from the hook's AMBIENT cwd, not from a `cd /abs/path &&` embedded inside the checked board.sh command (filed as #151). If a board.sh move to 'In review' reports BLOCKED with 'no recorded gate pass' right after a gate.sh run that visibly passed, the real cause is likely running from inside a worktree — exit the worktree (ExitWorktree keep) back to the main repo dir before the board.sh move, don't re-run the gate.
