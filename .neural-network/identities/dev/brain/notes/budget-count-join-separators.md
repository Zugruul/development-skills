---
tags: [budget, emission]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#4 review round 1"
graduated: false
created: 2026-07-07
---

When emitting budget-bounded concatenated blocks, count the join separators against the budget too. Found as a real 2-char overshoot in recall.

Related: [[stdout-newline-false-positive]]
