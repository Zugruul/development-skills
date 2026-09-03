---
tags: [review, orchestration, efficiency]
paths: ["**"]
strength: 1
source: "PR-close #310"
graduated: false
created: 2026-07-22
---

For a small diff that mirrors a just-reviewed sibling (same contract, same file family), one reviewer running BOTH passes as distinct sections preserves the two-pass structure at half the wall-clock — appropriate only when the sibling review just established the verification standard (flag-audit tables, probe patterns) and the diff is ≤~300 lines; full-size or novel work keeps separate reviewers.

Related: [[unresponsive-agent-take-over]] [[idle-agent-is-not-done]]
