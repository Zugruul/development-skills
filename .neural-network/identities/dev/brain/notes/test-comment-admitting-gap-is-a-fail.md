---
tags: [tests, honesty, coverage]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

A test whose own comment documents the path it avoids ("this path doesn't restore X, so exercise the other one") is a bug report mislabeled as a test-design constraint — the defect was found, described, and routed around. Treat writing (or reading) such a comment as a FAIL: fix the code path, don't design the test away from it.
