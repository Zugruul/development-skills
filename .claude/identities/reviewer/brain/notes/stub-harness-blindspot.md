---
tags: [testing, harness, review]
paths: []
strength: 1
source: "#318 retro"
graduated: false
created: 2026-07-25
---

A per-feature test harness that stubs the world proves the feature in a vacuum — cross-handler/cross-feature bugs live exactly in what the stub omits (the #318 Esc double-fire was structurally invisible to a harness that bound only the picker's handler). During review, statically trace all listeners/hooks sharing an event or resource with the diff, check for missing stopPropagation/ownership coordination, and require the harness to bind ALL the real cooperating handlers (with real event semantics like preventDefault flipping defaultPrevented) before trusting its green. Links: [[prescribe-contract-not-code]], [[measure-geometry-not-strings]].
