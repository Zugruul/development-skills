---
tags: [invariants, tests, contracts]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #447"
confidence: direct
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

A landed check may be an accidental PROXY for the real invariant — "zero .py files" was exactly right only while nothing but engine code was ever .py. When your change breaks a proxy's premise, the honest move is neither loosening carelessly nor treating the check as untouchable: state what the invariant is FOR, then rebuild the check around the true property (no engine modules) — and get the set arithmetic right when claiming the replacement's coverage (better ALIGNED is not "stricter").

Related: [[contract-invariant-preservation]]
