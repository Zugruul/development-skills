---
tags: [review, tdd, harness]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: 480
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Adaptation of [[red-commit-worktree-verify]] for harnesses that run each test file as ONE sequential eval script: an early throw at the red commit cascades FAIL onto many unrelated pre-existing checks in the same file, so "diff the failing-test-name set against green" does not cleanly apply. Instead prove the crash cannot leak beyond the touched files structurally — repo-wide grep that the new symbol is referenced only in the files under review — and treat the in-file cascade as expected collateral of the harness shape, not a hidden regression.

Related: [[red-commit-worktree-verify]]
