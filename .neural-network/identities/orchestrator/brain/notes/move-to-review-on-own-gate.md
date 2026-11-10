---
tags: [gate, parallel-lanes, worktree, board]
paths: [".claude/gate-pass", "plugins/spec-workflow/scripts/board.sh"]
strength: 1
source: "Zugruul/development-skills#571,#573"
confidence: direct
graduated: false
created: 2026-11-10
last-touched: 2026-11-10
---

# Move a lane to In review as soon as its own gate passes

The gate-pass marker is one shared file (.claude/gate-pass, #547). With two lanes gating in parallel, the later gate overwrites the earlier lane's pass, and its In review move is then refused. In #571/#573, #573's green gate was lost this way and cost an extra hour-long re-gate.

- When a lane reports a green gate, compare `tree-state.sh` in its worktree with the marker and move the card at once.
- Run `board.sh move` with the lane's own copy (`cd <worktree> && bash plugins/spec-workflow/scripts/board.sh ...`). Calling the primary checkout's board.sh by absolute path makes the guard check the primary tree.
- After merging one lane, rebase the next and re-gate before merging it.
