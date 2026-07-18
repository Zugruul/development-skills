---
tags: [review, concurrency, efficiency]
paths: ["**"]
strength: 1
source: "MEM-031/#218 same-session retro, 2026-07-18"
graduated: false
created: 2026-07-18
---

Two independent review dimensions (e.g. spec compliance and code quality) that don't depend on each other's findings can run as parallel reviewer agents instead of a sequential two-pass pipeline — cuts review wall-clock time without losing independence between the passes. Only sequence review rounds when round N genuinely needs round N-1's verdict (e.g. re-reviewing a fix).

Related: [[concurrent-gate-runs-collide]]
