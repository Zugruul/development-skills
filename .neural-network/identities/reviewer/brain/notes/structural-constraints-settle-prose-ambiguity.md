---
tags: [review, spec, ambiguity]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #340"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a spec sentence has two readings, look for a structural constraint elsewhere (a validator, a required field, a schema) that makes one reading BREAK — here a required-fields check two functions away turned "override just the TTL" into a silent unavailability under one reading, settling the prose decisively. A reading that breaks the spec's own use case is the wrong reading, and the argument is checkable rather than rhetorical.
