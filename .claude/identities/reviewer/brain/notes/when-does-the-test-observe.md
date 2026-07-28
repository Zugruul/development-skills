---
tags: [review, async, timing]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Beyond WHAT a test observes and at which LAYER, ask WHEN: an assertion at the right layer on the right object can be one tick early — the state it checks is destroyed by the next await. For async features, re-probe after every await boundary; a green assertion can also be green by coincidence (a stale variable happening to hold the right value), which reading the test never reveals — only re-running with varied state does.

Related: [[test-at-the-observed-layer]]
