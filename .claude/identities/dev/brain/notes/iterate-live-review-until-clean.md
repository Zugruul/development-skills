---
tags: [tdd, codex, peer-review, process]
paths: []
strength: 1
source: "PRV-004 (#201) development, 4 live self-review rounds"
graduated: false
created: 2026-07-16
---

A single live self-review of a merged diff can surface multiple real, independent bugs across several rounds -- don't stop iterating after the first finding if you're using an external reviewer as part of TDD/QA. In PRV-004's development, 7 distinct genuine issues were found across 4 live codex review passes (a missing file commit, an AskUserQuestion cardinality violation, an over-strict eligibility filter, an ordering/invariant violation, a Python bool-is-int gotcha, an empty-slug gap, and post-merge a flag-value-swallowing gap) -- treat each pass's clean result as real signal to stop, not a fixed iteration count.
