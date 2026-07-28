---
tags: [review, invariants, assumptions]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #424"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

"X is safe BECAUSE Y" is an edge in a dependency graph that no diff, type, or test represents — an edit to Y never appears in a diff of X. When a diff changes an ASSUMPTION, grep for who depends on it; when it deliberately reverses a landed decision, re-read the ORIGINAL rationale first and enumerate what it claimed to rest on. The review question is not "is the new behavior right?" but "what did the old contract's correctness rest on, and does that still hold?" — the well-argued reversal answered the first thoroughly and never asked the second.

Related: [[true-or-merely-true-today]] [[record-why-safe-not-just-that]]
