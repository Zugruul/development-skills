---
tags: [board, review, scope]
paths: ["**"]
strength: 1
source: "retro AST-030/031"
graduated: false
created: 2026-07-24
---

When a diff legitimately delivers a neighboring task's full AC through an existing seam, reconcile the BOARD, not the code: close the neighbor citing the delivering merge SHA and the test evidence, in the same close-out as the delivering task. Trimming correct wiring to preserve task boundaries, or rebuilding the neighbor as a duplicate, are both worse than an honest reconciliation comment. The reviewer's overlap flag is the trigger.

Related: [[mode-elastic-loop]] [[live-validation-is-loop-input]]
