---
tags: [testing, fixtures, tdd]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#140 MEM-032 self-review while writing regression test"
graduated: false
created: 2026-07-18
---

When writing a fixture meant to prove "reachable only via path X (e.g. link-spread), not via path Y (e.g. direct top-K selection)," explicitly verify path Y is actually closed for the target note (e.g. inspect what the neighbor-selection step itself returns, not just the final recall output) before trusting the higher-level assertion. Also keep --k (or any breadth/fan-out parameter) small and explicit in adversarial tests -- a generous default trivially includes everything and hides ranking/filtering bugs entirely.

Recurrence (MEM-032): a fake embedder's fallback vector for zero-shared-vocabulary text was nonzero, so a note intended as "only reachable via link bridging" was silently getting directly top-K-selected regardless of any bug in the bridging mechanism the test was built to isolate -- caught only by tracing through what the neighbor-selection step actually returned for that note.

Related: [[vocab-dict-fake-embedder]] [[audit-new-path-parity-before-writing]]
