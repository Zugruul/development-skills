---
tags: [dispatch, receipts, ownership, testing]
paths: ["plugins/remote-compute/scripts/remote-compute.py"]
strength: 1
source: "issue-525-review-round-1"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Distinguish The Outcomes
Classify a dispatch result as accepted, definitely refused, or uncertain before writing recovery state. A definite job-ID refusal must not create a receipt for the target's existing job.

## Verify Consequences
A local receipt may enable status, logs, artifact retrieval and cancellation by ID. Seed a job owned by a different controller, reproduce the refusal through the public CLI, then prove those follow-on operations cannot act through the rejected invocation. Keep unknown receipts for genuinely ambiguous acceptance and never fail over after it.

Related: [[boundary-test-needs-exact-value-plus-absence-check]] [[deterministic-repro-fast]]
