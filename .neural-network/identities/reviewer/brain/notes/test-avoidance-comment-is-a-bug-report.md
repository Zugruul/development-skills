---
tags: [review, tests, smells]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a test comment explains why it avoids a code path, read it as a bug report: the author found the defect, described it accurately, and mislabeled it as a test-design constraint. That comment was the single highest-value line in the diff — grep test files for "only", "doesn't", "instead" near path choices.
