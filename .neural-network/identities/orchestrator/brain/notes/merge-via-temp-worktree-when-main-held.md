---
tags: [git, worktree, merge, work-type-local]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255 close
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

When another session's worktree holds `main` checked out (git refuses `git switch main` in this clone), the local-route merge still works cleanly: `git worktree add <tmp> origin/main`, `git merge --squash <branch>` + attributed commit there, `git push origin HEAD:main`, remove the worktree, then `git switch --detach origin/main` in this clone. Never remove or touch the foreign worktree — it is another session's live state. Flag the held-main situation in the iteration report so the human knows the clone is detached.

Related: [[board-moves-before-branch-delete]]
