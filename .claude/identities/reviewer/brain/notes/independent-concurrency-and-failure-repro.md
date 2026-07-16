---
tags: [review, concurrency, verification]
paths: []
strength: 1
source: "task #133 (MEM-020) review"
graduated: false
created: 2026-07-16
---

For a shared-foundation task whose atomicity/concurrency claim other tasks will rely on, run an INDEPENDENT concurrency test beyond the dev's own (different N, different payload shape) and force a REAL failure condition yourself (e.g. an unwritable path) rather than reading the failure-handling code and trusting it.

Why: reviewing #133 (MEM-020), re-running the dev's exact N=30 test only proves their specific scenario; running an independent N=80 test with larger padded lines, and separately making .claude an unwritable regular file to force emit_event's real failure path, is what actually confirmed both the atomicity and non-blocking-failure guarantees hold beyond the one scenario the dev happened to test.

How to apply: for concurrency/atomicity/failure-handling claims specifically (as opposed to ordinary logic), re-running the dev's own test is necessary but not sufficient -- construct your own independent stress parameters and your own real failure trigger before approving.
