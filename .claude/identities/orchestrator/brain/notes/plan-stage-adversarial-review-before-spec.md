---
tags: [planning, review, security]
paths: []
strength: 1
source: "retro 2026-07-22 (assistant spec, PR#356)"
graduated: false
created: 2026-07-22
---

Run an implementation plan through 2+ independent agent reviewers (different models, at least one grounded in the actual codebase with file:line citations) BEFORE drafting the spec. Plan stage is the cheapest point to catch security-by-design flaws and false assumptions — here it caught a shell-injection invoke design, a harness-isolation gap, and a wrong "recall is read-only" assumption that code review would have found only after implementation. Fold findings in as spec requirements/invariants, not as later review comments. Related: [[ui-rounds-converge-via-favorite-plus-aspects]].
