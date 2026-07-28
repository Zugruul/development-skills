---
tags: [tests, pins, completeness]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #441"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

This codebase deliberately spreads behavior pins across multiple test section files by feature area — updating the section you were editing is not the same as finding every place the old behavior is asserted. Before declaring any template/behavior change done: grep -rl the changed symbol across the WHOLE test tree. A missed third section cost a review round as a gate-blocking stale-pin cluster.
