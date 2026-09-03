---
tags: [review, concurrency, worktrees]
paths: ["**"]
strength: 2
source: "#80 review retro — recurrence (stale-cwd wrong findings)"
graduated: false
created: 2026-07-08
---

Multi-lane sessions repoint the shell cwd BETWEEN tool calls — a reviewer greping a stale checkout produced a round of wrong findings before file contents mismatched the diff. The explicit `cd <lane> && ` prefix is load-bearing on EVERY command, no exceptions; cross-check `git diff --name-only`/`pwd` against expectations before trusting any result.

Related: [[red-commit-worktree-verify]] [[diff-against-merge-base]]
