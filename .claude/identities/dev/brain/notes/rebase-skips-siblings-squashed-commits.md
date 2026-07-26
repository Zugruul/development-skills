---
tags: [git, worktrees, process]
paths: []
strength: 1
source: "#405 rebase 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Rebasing a branch forked from an in-flight sibling: the sibling's LATER fix commits get folded into its eventual squash-merge, so your copies of its ORIGINAL commits no longer match main patch-id-wise and will conflict — skip them explicitly (git rebase --skip; their effect is already in main's squash), never hand-resolve them.

Related: [[resumed-branch-staleness-pass]]
