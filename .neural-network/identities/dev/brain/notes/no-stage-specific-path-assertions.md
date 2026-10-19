---
tags: [tests, spec-delta, workflow-stages]
paths: ["plugins/spec-workflow/tests/**"]
strength: 2
source: "#241 retrospective: independently reproduced workflow boundary"
confidence: direct
graduated: false
created: 2026-07-22
last-touched: 2026-10-19
---

## Cover every legitimate stage

A test for a workflow artifact must survive the workflow that publishes it. Spec deltas move from a pending directory into `applied/` at merge; accept either legitimate location or verify the folded content.

## Keep the assertion meaningful

Exercise both pending and applied states, then remove both artifacts and confirm the assertion fails. A branch-only positive test can hide a guaranteed failure after merge.

Related: [[sourced-section-no-brace-cd]] [[batch-red-across-surfaces]]
