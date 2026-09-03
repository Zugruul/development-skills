---
tags: [concurrency, locks, coordination]
paths: []
strength: 1
source: "#412 incidents 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

A bare mkdir lock without an owner file and liveness rule politeness-deadlocks: two agents each assumed the other held it while nobody ran anything (3 stall incidents in one day, incl. a stale wait-loop grabbing the lock invisibly). Protocol that worked: owner file written on acquire, stale = age>25min with zero suite processes, and when agents still deadlock, the orchestrator assigns EXPLICIT turns ('it is your turn, go now') instead of letting them self-coordinate. Mechanical fix tracked #412 (flock in gate.sh).

Related: [[inventory-stalled-agent-tree]]
