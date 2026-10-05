---
tags: [delegation, testing, safety]
paths: ["plugins/spec-workflow/scripts/neural-view.py"]
strength: 1
source: "feedback 2026-08-01 item 3, sidecar outage"
confidence: direct
graduated: false
created: 2026-08-01
last-touched: 2026-08-01
---

Validator/test briefs must forbid scratch instances from managing machine-global resources and must require restoring any global service the run may have disturbed, verified healthy, before the agent finishes. A state-scoped scratch server stopping a machine-global voice sidecar took down live user-facing input; scoping lifecycle ownership to the owning state dir is the systemic fix.
