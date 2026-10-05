---
tags: [review, tests, regression, discrimination]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #305 r2/r3"
graduated: false
created: 2026-07-22
---

A regression test for a specific code-path fix must be proven to REACH that path: the drafted unparseable-yaml fixture was valid YAML (a flow list), so it exercised the wrong-shape refusal and stayed green even with the fix reverted — twice in one task a test targeted the wrong verb/path. Standard proof: revert-run-restore (checks FAIL at the pre-fix commit, pass at the fix commit). Cheap, and the only evidence that the test guards the thing that was broken.

Related: [[check-empty-expected-vacuous]] [[mutation-check-assertions]]
