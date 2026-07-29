---
tags: [gate, process, concurrency]
paths: []
strength: 1
source: "loop-feedback 2026-07-29"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A recorded full-suite gate pass races ANY concurrent edit: the pass fingerprints the tree, so a background gate run plus live editing burns the whole suite runtime to record a stale verdict. Freeze edits for the run's duration (do investigation/reads instead), or abort the run the moment more edits are queued — two full runs were wasted this way in one session.
