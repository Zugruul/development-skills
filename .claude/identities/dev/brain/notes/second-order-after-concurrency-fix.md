---
tags: [concurrency, design]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#92 retro"
graduated: false
created: 2026-07-08
---

When fixing a race in a just-shipped feature, assume the first fix is incomplete: after "does it stop the loss?", ask "what happens to an op that SURVIVES the race but arrives out of order?" — the mutex stopped op loss and thereby ENABLED the staleness reordering that never used to arise (lost ops can't reorder). Prefer signals already in the data (the ts field was a free recency key) over inventing sequence counters.

Related: [[pair-every-side-effect-with-undo]] [[normalize-after-load-identity-fields]]
