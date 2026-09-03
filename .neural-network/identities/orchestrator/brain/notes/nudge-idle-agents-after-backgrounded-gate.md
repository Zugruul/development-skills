---
tags: [orchestration, concurrency]
paths: []
strength: 1
source: "retro"
learned-from: tasks 154/158 close
graduated: false
created: 2026-07-12
---


# A silent idle after a backgrounded gate is a stall — nudge immediately

Dev agents that kick a long gate and go "idle/available" without a report have
almost always dropped the ball on delivery, not finished it. On the idle
notification: state-check (branch commits, recorded pass, PR), and if delivery
is incomplete, send a concrete next-actions nudge rather than waiting a full
heartbeat. Related: [[worktree-lanes-when-tree-is-shared]]
