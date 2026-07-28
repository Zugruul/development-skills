---
tags: [tests, grep, pins]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #438/#441"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

grep -F with an embedded newline treats each LINE as a separate pattern with OR semantics — a multi-line content pin passes if ANY single line matches, so the check can stay green with the feature entirely absent. Pin one unique line per check, or split into multiple checks. Caught only by reading RED output line-by-line, and reintroduced one line away the same day it was documented — check the whole diff for the class, not just the site where you learned it.
