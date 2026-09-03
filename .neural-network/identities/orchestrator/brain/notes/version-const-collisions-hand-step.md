---
tags: [integration, merges, versioning]
paths: []
strength: 1
source: "voice/UI batches 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

When several lanes bump one version constant, git may auto-resolve identical bumps with NO conflict and the features silently share (or lose) a version step — the orchestrator hand-steps the const per merge in dance order and updates every test pin that references it (pins move with the head version, annotate why). Resolved a three-way NV_VERSION collision this way (0.28.8/9/10/11).

Related: [[locks-need-owner-liveness-and-turns]]
