---
tags: [concurrency, agent-orchestration, worktree]
paths: ["**"]
strength: 1
source: "MEM-031/#218 same-session retro, 2026-07-18"
graduated: false
created: 2026-07-18
---

When the orchestrator shares a git working tree with a spawned dev subagent (no isolation:worktree set) and needs to switch branches for unrelated work mid-task, the dev agent can self-mitigate by creating its own `git worktree add` off the same branch and continuing there rather than blocking or corrupting shared state — this actually worked cleanly in practice (MEM-031's fix round). But the better fix is upstream: when the orchestrator anticipates doing other branch-switching work in the same session while a dev agent is active, spawn that dev agent with isolation:'worktree' from the start rather than relying on the dev agent's own defensive recovery.

Related: [[concurrent-gate-runs-collide]]
