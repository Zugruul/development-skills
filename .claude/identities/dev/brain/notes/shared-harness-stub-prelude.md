---
tags: [testing, harness, template]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "loop-feedback 2026-07-29"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

When a UI template's hermetic harnesses extract functions individually (regex extraction + eval against DOM stubs), every NEW call edge between template functions breaks every harness extracting the caller — the failure is always 'X is not defined' at eval time, one harness at a time. Budget for a stub-chasing pass after any cross-function wiring change, and prefer adding a shared default-stub prelude (no-op recorders for known template hooks) over per-site hand stubs: four separate patch rounds in one session came from exactly this shape.
