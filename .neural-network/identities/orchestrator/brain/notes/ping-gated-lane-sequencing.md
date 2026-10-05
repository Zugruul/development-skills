---
tags: [coordination, merges, delegation]
paths: []
strength: 1
source: "wave-2 dances 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

When branch B's fix depends on branch A landing first, hold B explicitly ('do NOT start until I ping main-ready') and send the ping with the exact new state (tip hash, version values). Two clean executions (050 after 051; 430 after 428/429) — no premature rebases, no re-work, no idle-guess loops.

Related: [[version-const-collisions-hand-step]] [[brief-collisions-and-inflight-siblings]]
