---
tags: [review, tdd, verification]
paths: []
strength: 1
source: "PRV-001 review (reviewer-prv001)"
graduated: false
created: 2026-07-15
---

Verify red-first TDD independently, not just via git log message text -- actually checkout the claimed red commit in a scratch worktree and run the suite to confirm it genuinely fails (and how). A commit message alone can't prove the test was ever run against a missing implementation.
