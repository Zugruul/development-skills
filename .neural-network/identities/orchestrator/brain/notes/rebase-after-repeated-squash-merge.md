---
tags: [git, merge, workflow]
paths: []
strength: 1
source: "feedback item 0, 2026-07-11T04:20:00Z"
graduated: false
created: 2026-07-11
---

Reusing one long-lived feature branch across several squash-merges
diverges it from main every single time — each squash creates a new
commit hash for content that's already identical to what the branch had.
The next PR from that branch then reports CONFLICTING even though nothing
semantically conflicts. Recognize it (diff the branch's own merge-point
commit against the new main tip — empty diff confirms it) and resolve with
`git rebase --onto <new-main> <old-merge-point> <branch-tip>`, not a manual
conflict-by-conflict merge. Prefer a fresh branch per PR when doing
iterative same-area work across multiple merges.
