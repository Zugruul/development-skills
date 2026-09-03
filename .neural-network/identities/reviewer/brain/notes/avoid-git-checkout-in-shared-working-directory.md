---
tags: [review, git, concurrency]
paths: ["**"]
strength: 1
source: "PR#242 (#234) review -- used in-place file swaps / a temp worktree instead of git checkout to verify TDD without disrupting other active lanes sharing this working directory"
graduated: false
created: 2026-07-20
---

When verifying TDD (reverting files to a prior state, re-running tests, restoring) in a shared working directory other agents may be actively using, avoid `git checkout <branch>` (which repoints the WHOLE shared tree and could yank another lane's in-progress files out from under it) -- instead swap individual files in place (copy/write the old content, test, restore the new content) or use a temporary git worktree scoped to just your own verification. This session had a real incident where a delayed subagent found its checkout had moved to a different task's branch; a reviewer correctly avoided causing the same problem for someone else by using file-swaps/worktrees instead of checkout.

Related: [[verify-branch-state-before-acting-in-shared-checkout]]
