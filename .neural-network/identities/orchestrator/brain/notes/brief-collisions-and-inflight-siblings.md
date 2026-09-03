---
tags: [briefing, delegation, git]
paths: []
strength: 1
source: "#404+#405 retro"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Dev briefs must flag (a) pre-existing same-name surfaces the task will collide with (changelog.sh/#165 already existed when #404 built changelog.py — dev burned an exploration pass discovering it) and (b) sibling branches still in flight that the new branch forks from (#405 forked from moving #404 and hit rebase conflicts from its later fix commits). One brief line each — 'X already exists, extend not replace' / 'sibling may still move; skip its commits on rebase' — saves a real investigation per lane.

Related: [[brief-load-bearing-lines]]
