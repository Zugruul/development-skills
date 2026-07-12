---
tags: [git, delivery]
paths: []
strength: 1
source: "retro"
learned-from: task 158 close
graduated: false
created: 2026-07-12
---


# Lanes cut from unpushed mainline need a reconciliation step before PR

When a task must build on unpushed local-mainline commits, cut the lane from
local main and HOLD the PR: opening it early would carry someone else's
unpushed commits. To deliver: rebase mainline onto origin and push it, then
`git rebase --onto <new-main> <old-base> <lane>` (duplicated cherry-picks drop
automatically) and force-push-with-lease the lane. Only then open the PR.
Related: [[worktree-lanes-when-tree-is-shared]]
