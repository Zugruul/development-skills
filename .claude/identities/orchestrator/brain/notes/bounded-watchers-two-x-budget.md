---
tags: [process, monitoring, timeouts]
paths: []
strength: 1
source: "human directive 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Every watcher/poll loop gets a hard iteration cap sized 2x the watched operation's nominal duration (gate ~7min => 15min cap, also the human-set maximum: a slower gate must be optimized, not waited on). An unbounded watcher with a wrong predicate (grepping for a line that never lands in that file) spun for 2h before the human found it. Config knob tracked #414.

Related: [[after-wait-do-the-mutation]]
