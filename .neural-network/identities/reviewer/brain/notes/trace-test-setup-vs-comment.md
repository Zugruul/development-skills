---
tags: [review, fixtures, anti-circularity]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#140 MEM-032 review round 1"
graduated: false
created: 2026-07-18
---

A test comment/description is a claim about what the test does, not a fact — before crediting it, grep the WHOLE test file for every actual setup call (e.g. every `index`/config/fixture-building invocation) and diff that against what the comment says happens. A comment can accurately describe a stub's internal mechanism (e.g. why its vectors are non-collinear) while still being wrong about how/whether that stub gets exercised elsewhere in the file.

Recurrence (MEM-032 quality review): a "golden-identical when sidecar absent" test's comment claimed one fixture role had the embedding index built (with keywords that just do not match); grepping the file for every `index` call showed it was never invoked — both compared roles were actually unindexed, so the test only proved two identical no-op setups produce identical output, a much weaker check than claimed.

Related: [[verify-guard-regex-on-real-artifact]]
