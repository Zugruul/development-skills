---
tags: [caching, concurrency, design]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#78 retro"
graduated: false
created: 2026-07-08
---

Before making any read cache-first, ask: does this read exist to DETECT a change I might not know about yet? Then it's a guard, not an optimization target — a cache only reflects what this process successfully did; it cannot know about queued-but-unapplied ops or out-of-band remote changes. Corollaries: gate-fingerprint exclusions are an explicit convention (every new gitignored file a routine mutation writes needs adding, or ops invalidate unrelated passes); measured-claim tests (call counts, error text) catch bugs pass/fail tests structurally can't (a failing cache WRITE turning a real hit into a false miss).

Related: [[second-order-after-concurrency-fix]] [[equality-guards-invite-ordering-probes]]
