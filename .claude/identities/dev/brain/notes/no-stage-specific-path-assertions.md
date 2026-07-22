---
tags: [tests, spec-delta, workflow-stages]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-021 #256 hotfix
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Never assert a file at a path that a LATER workflow stage legitimately moves: kb-seed's AC7 test pinned docs/spec-deltas/GL-050.md, which the In-review->QA fold moves to applied/gl-300.md — the test was green in the PR and guaranteed-red on main after close. For workflow-artifact assertions, accept every legitimate lifecycle location (pending OR applied) or assert content presence in the folded target, and note the lifecycle in a comment.

Related: [[sourced-section-no-brace-cd]] [[batch-red-across-surfaces]]
