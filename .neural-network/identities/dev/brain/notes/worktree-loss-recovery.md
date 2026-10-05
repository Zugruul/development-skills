---
tags: [git, worktrees, ops]
paths: ["**"]
strength: 1
source: "#86 retro (orchestrator-caused deletion)"
graduated: false
created: 2026-07-08
---

Worktree directories are disposable; branch refs are not. On a vanished worktree: git worktree list → prune -v → add <path> <branch> recovers cleanly. BEFORE reconstructing files from memory, confirm via git log which commits actually landed — reconstruct the exact known delta, don't guess at what was saved.

Related: [[deterministic-repro-fast]]
