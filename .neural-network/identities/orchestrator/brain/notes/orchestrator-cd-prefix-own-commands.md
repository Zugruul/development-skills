---
tags: [orchestration, worktrees, git]
paths: ["**"]
strength: 2
source: "fourth slip: sw-86's worktree created NESTED inside sw-55 via drifted cwd; deleted with sw-55's retirement, destroying a dev's uncommitted work"
graduated: false
created: 2026-07-08
---

The orchestrator's OWN shell drifts exactly like the agents' — four incidents this session, the worst: `git worktree add .claude/worktrees/sw-86` ran with cwd inside sw-55's lane, nesting the new worktree INSIDE it; retiring sw-55 then deleted sw-86's directory mid-task and destroyed a dev's uncommitted work. EVERY orchestrator command — worktree add/remove above all — starts with `cd <main checkout absolute path> && `, and worktree adds are verified with `git worktree list | grep <name>` showing the expected ABSOLUTE path before any agent is briefed into it.

Related: [[board-comment-bodies-via-file]] [[pre-diagnose-before-brief]]
