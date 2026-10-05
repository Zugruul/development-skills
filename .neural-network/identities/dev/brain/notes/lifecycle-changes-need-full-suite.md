---
tags: [tests, lifecycle, signals, concurrency]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #308 dev self-caught"
graduated: false
created: 2026-07-22
---

A lifecycle-touching change (signal handlers, shutdown latency, daemon threads) can break OTHER sections' rapid stop→start sequences while your own new section stays green — full-suite evidence is the only valid green claim for lifecycle changes; an isolated --section run is structurally blind to it. Seen live: adding graceful SIGTERM shifted stop latency and broke 29 checks across the suite until stop gained a bounded wait-for-exit.

Related: [[deterministic-repro-fast]] [[marker-barrier-interleave]]
