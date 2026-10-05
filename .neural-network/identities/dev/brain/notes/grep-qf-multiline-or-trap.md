---
tags: [tests, bash, grep, vacuous]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #305 dev CONSULT"
graduated: false
created: 2026-07-22
---

grep -qF with an embedded-newline pattern ($'a\nb') does NOT match a literal multi-line substring — grep treats each line of the pattern as an OR'd alternative, so multi-line assertions pass on wrong content. For structured file content, assert via the owning tool's readback (config.py get) instead of grepping raw text.

Related: [[test-section-shell-plumbing-risk]] [[check-empty-expected-vacuous]]
