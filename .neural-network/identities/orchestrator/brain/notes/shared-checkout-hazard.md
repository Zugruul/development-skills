---
tags: [git, worktree, process]
paths: []
strength: 1
source: "PR#5/#6 merge window incidents"
graduated: false
created: 2026-07-07
---

The main checkout and every agent worktree belong to the agent working there. Orchestrator merge chores (switch/pull/peek) in an occupied workspace caused two incidents: a mid-rebase race and unreviewed commits landing on main. Always chore from a dedicated orchestrator worktree.

Related: [[post-hoc-review-over-rewrite]]
