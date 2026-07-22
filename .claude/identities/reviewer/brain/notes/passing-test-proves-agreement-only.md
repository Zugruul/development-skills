---
tags: [review, tests, verification, math]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300 review
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

A passing test proves only that the code and the test agree with each other — not that either is right. For numeric assertions (thresholds, percentages), redo the arithmetic yourself against the underlying formula (e.g. shrink guard's remove_count/total_count with its floor) before accepting the asserted literal. And when reused code's user-facing wording mismatches its new context (guard says "remove" for in-place updates), flag it as a non-blocking note rather than staying silent because the test passed — spec-compliant is not the same as right.

Related: [[dual-path-fixture-proves-sharing]] [[verify-reuse-by-symbol-grep]]
