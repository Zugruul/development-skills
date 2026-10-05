---
tags: [review, hazard-classes]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close batch #438/#441"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

A dev documenting a hazard class does not prevent them reintroducing it one line away — twice in one batch, the same dev correctly explained a trap (multi-line grep OR-semantics; JS-string escaping) and then re-created the identical class in the adjacent check or the adjacent parser context. When a diff shows awareness of a hazard class, review the REST of the diff specifically for other members of that class.

Related: [[test-at-the-observed-layer]]
