---
tags: [review, verification, testing]
paths: ["plugins/spec-workflow/templates"]
strength: 1
source: "retro 379-381 (review round 2)"
graduated: false
created: 2026-07-23
---

When a fix states a guarantee ("X always self-matches"), treat that sentence as a test-generation prompt: execute the changed code against adversarial inputs the new tests did not sample (doubled separators, empty, boundary lengths) instead of only reading the diff. A live-executed counterexample at review time is a one-line round-2 fix; the same defect post-merge is a new bug report.

Related: [[reproduce-red-first-claims]] [[degrade-path-kind-honesty]]
