---
tags: [worktree, concurrency, isolation, process]
paths: ["plugins/spec-workflow/skills/build-next"]
strength: 2
source: "human direction 2026-08-01: dev lanes in worktrees, primary checkout stays on main"
confidence: direct
graduated: false
created: 2026-07-22
last-touched: 2026-08-01
---

Dev lanes run in worktrees (.claude/worktrees/sw-<id>) even when work is sequential — the primary checkout stays on the main branch at all times so the human's terminal, other sessions, and orchestrator main-branch work are never disturbed by an in-flight task branch. Human-directed 2026-08-01 after a lane ran in the primary checkout. Relocating a live lane: stash -u, switch primary to main, worktree add for the branch, stash apply inside the worktree, drop the stash, redirect the dev agent with absolute paths.
