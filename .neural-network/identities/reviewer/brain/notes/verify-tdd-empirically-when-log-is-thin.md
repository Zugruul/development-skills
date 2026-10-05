---
tags: [review, tdd, verification]
paths: ["**"]
strength: 2
source: "PR#224 (CDX-012, #182) -- re-applied successfully, this time on a red-then-green two-commit branch (still verified empirically rather than trusting the commit sequence alone)"
graduated: false
created: 2026-07-19
---

When a diff is small enough that git log alone can't prove tests were red before the fix (e.g. one dev-agent commit, no red-commit history), verify TDD empirically instead of trusting the PR body: check out the pre-change version of the touched non-test files against the new test file and re-run the relevant test section -- confirm it fails, then restore and confirm green. Cheap, and it catches a test that accidentally passes even against the old behavior (weak assertion, wrong path, etc).

Related: [[verify-red-test-genuinely-discriminates]]
