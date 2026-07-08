---
tags: [review, tdd, git]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR#69 (#68) retro"
graduated: false
created: 2026-07-07
---

Verify a red-first TDD claim by running the full suite at the red commit inside an isolated `git worktree add` — never `git checkout <sha> -- <path>` into the current tree (mixed dirty state, stash confusion). The worktree run also proves the red failures are EXACTLY the new checks, a stronger signal than reading the diff.

Related: [[recompute-hashes-never-eyeball]]
