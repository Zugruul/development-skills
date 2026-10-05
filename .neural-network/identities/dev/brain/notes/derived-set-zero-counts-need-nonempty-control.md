---
tags: [tests, vacuity, absence-proofs]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #447"
confidence: direct
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Any check that counts hits over a DERIVED set (a glob, a grep, a scan) needs to prove the set itself is non-empty first — an empty derivation yields zero iterations and a green check that tested nothing. Generalizes the never-spawns/disabled-capability positive-control pattern to every find/grep/derived-list zero-count; apply proactively, not on review demand.
