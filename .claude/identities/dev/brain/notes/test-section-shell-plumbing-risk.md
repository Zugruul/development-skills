---
tags: [tests, bash, quoting, python]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #301 dev interview"
graduated: false
created: 2026-07-22
---

In new-module tasks here the real defect risk concentrates in the bash test-section plumbing, not the code under test — double-quoted strings need no \x27-style escapes (bash would keep them literally, making an assertion unmatchable), and helper functions forwarding python -c bodies must shift-and-forward "$@" or every sys.argv-based check silently breaks. Reread the test diff BEFORE the first run; both near-misses were caught by rereading, neither would have failed loudly.

Related: [[extend-house-fixture-style]]
