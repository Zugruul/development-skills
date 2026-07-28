---
tags: [review, omissions, audit]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #340"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Reviewing a deliberate omission ("existing coverage suffices") is a different skill than reviewing an addition: verify the SPECIFIC sibling assertions — open the file, read the line, confirm it asserts the claim rather than something adjacent. A green sibling section is NOT evidence; two greps are the whole cost.
