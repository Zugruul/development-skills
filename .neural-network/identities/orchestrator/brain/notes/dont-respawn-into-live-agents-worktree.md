---
tags: [worktree, concurrency, bug]
paths: []
strength: 1
source: "#171 -- dev-171 and dev-171b both live in sw+171 simultaneously"
graduated: false
created: 2026-07-15
---

Spawning a retry agent into the SAME worktree path as a still-running (not-yet-confirmed-stopped) original agent is unsafe even if the original reported a hard blocker -- the blocker report doesn't guarantee the original process has actually exited. Two live agents editing the same shared worktree can race on the same files; it only resolves cleanly by luck (identical briefs producing identical content), not by design. Confirm the original is actually terminated, or use a distinct worktree for the retry, before respawning into the same path.
