---
tags: [review, comments, premises]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #447"
confidence: direct
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Prose in comments deserves code-level scrutiny: the only wrong thing in an otherwise-correct diff was a comment claiming the new checks were "stricter" (set-wise strictly weaker) — and comments are exactly what the next reviewer trusts instead of re-deriving. A recorded premise can be load-bearing AND false; check the claim's arithmetic, not its plausibility.

Related: [[record-why-safe-not-just-that]]
