---
tags: [worktree, concurrency, isolation, process]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-021 #256 (human-directed)
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Human-directed standing practice: every build-loop task runs in its OWN worktree cut from fresh origin/main (branch sw/<id>-<slug>), the dev agent is briefed with the absolute worktree path and forbidden from touching the parent clone, and at task close the branch is squash-merged (push HEAD:main) and the worktree removed before the next task. This eliminated the entire shared-clone collision class (stash accidents, foreign dirty runtime files, held-main checkout) that caused real incidents in earlier iterations.

Related: [[merge-via-temp-worktree-when-main-held]] [[board-moves-before-branch-delete]]
