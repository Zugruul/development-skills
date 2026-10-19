---
tags: [worktrees, checkpoint, preflight]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "development-skills#239 implementation and independent review"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Keep code and shared state roots separate

- Resolve pause flags and other clone-wide loop state through the primary checkout.
- Keep spec validation, source inspection and gate execution rooted in the current worktree.
- Add a divergent-worktree regression: a missing spec in the task tree must still fail even when the primary checkout is valid.

Changing a script's global ROOT to fix one shared-state lookup can silently redirect unrelated checks. Pass a separate state root to the new guard instead.

Related: [[batch-red-across-surfaces]] [[acceptance-criterion-outranks-test-spec-paraphrase]]
