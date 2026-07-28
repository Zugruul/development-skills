---
tags: [review, probes, evidence]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #334"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Probe with the project's OWN test harness plus print statements, not hand-written mocks: findings become undeniable (their setup, their stubs) and rounds become apples-to-apples — the round-2 re-run is the same probe, so the before/after needs no argument.

Related: [[reproduce-before-verdict]]
