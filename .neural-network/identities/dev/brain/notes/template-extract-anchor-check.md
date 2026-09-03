---
tags: [tests, regex, templates]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#69 (#68) retro"
graduated: false
created: 2026-07-07
---

The test suite's extract() pattern anchors a function's end on a standalone closing-brace line — before reusing it on a new function, grep the target's byte range for a premature '^}$' match instead of assuming the anchor generalizes. A silently short extraction makes an eval-based test pass vacuously.

Related: [[hermetic-tmpdir-per-guard-case]]
