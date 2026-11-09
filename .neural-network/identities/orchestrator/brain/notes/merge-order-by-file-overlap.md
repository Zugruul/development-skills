---
tags: [orchestration, merge, gates]
paths: []
strength: 1
source: "#560-#567"
confidence: direct
graduated: false
created: 2026-11-09
last-touched: 2026-11-09
---

With one shared gate-pass marker and a rebase-and-regate rule, every merge into main invalidates every other lane's gate.

## What happened
- Eight lanes merged one by one; each merge forced the next lane to rebase and run a fresh 40-minute gate, and two lanes needed hand-merged parsers.

## What to do
- Before starting lanes, map which files each will touch and merge the ones that share files back to back, smallest first.
- Merge as soon as a lane is approved, rather than batching, so rebases stay small.
- Never rebase a worktree while its gate is running.
