---
tags: [review, prescriptions]
paths: []
strength: 1
source: "#318 retro"
graduated: false
created: 2026-07-25
---

When a finding is airtight, prescribe the CONTRACT ("on Escape, the picker must not skip when the chat overlay owned the keypress"), not a concrete patch — a code-level prescription you haven't execution-traced is an untested patch shipped inside a review (the #318 re-query prescription would itself have raced). Prescribe an implementation only after tracing its execution order. Separately verify reachability of a finding and soundness of its fix — the same handler-order reasoning that makes a bug real makes or breaks the fix. On verify rounds, always re-run the red at the test-only commit: a fix is proven only when its test fails without it. Links: [[measure-geometry-not-strings]].
