---
tags: [git, worktrees, merge]
paths: ["**"]
strength: 1
source: "PR#229 (CDX-021, #186) merge -- reviewer's /private/tmp/main-baseline worktree blocked gh pr merge's branch cleanup step"
graduated: false
created: 2026-07-19
---

A reviewer subagent that creates a temporary git worktree checked out on a branch name (e.g. "main") for baseline diffing can leave it behind, silently blocking a later `git`-based operation (gh pr merge's internal branch-delete step failed with "'main' is already used by worktree at ..."). Check `git worktree list` for stray worktrees checked out on a branch you're about to operate on (merge target, delete target) before assuming a git-command failure is a real problem -- `git worktree remove <path>` clears it, and the original operation (e.g. gh pr merge) often already succeeded remotely even though the local step errored.

Related: [[worktree-loss-recovery]]
