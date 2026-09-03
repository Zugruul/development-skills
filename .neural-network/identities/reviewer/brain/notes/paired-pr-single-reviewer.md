---
tags: [review, concurrency]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 E1 iteration
graduated: false
created: 2026-07-07
---

When two concurrent PRs touch one subsystem, review them with ONE agent holding both diffs: cross-PR regressions (one PR removing behavior the other depends on) are structurally invisible to isolated per-PR reviews. This caught a critical guard bypass. Related: [[symmetric-boundary-guards]].
