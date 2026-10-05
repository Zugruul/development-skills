---
tags: [tests, concurrency, race, determinism]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #304 fix r1"
graduated: false
created: 2026-07-22
---

To force a specific race interleave deterministically in tests, use a marker-file barrier: the read-modify-write side writes a marker right after its READ and sleeps; the concurrent writer polls for the marker before starting; assertions then check whose write survived. Converts a 7-of-9 scheduling-dependent repro into a 100% deterministic probe — the standard follow-up once a natural repro exists (per [[deterministic-repro-fast]]).

Related: [[deterministic-repro-fast]] [[test-section-shell-plumbing-risk]]
