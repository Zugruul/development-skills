---
tags: [tdd, tests]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#61 (#60) retro"
graduated: false
created: 2026-07-07
---

Static-file checks (sha/integrity) and wiring checks (allowlist/route) are different failure modes and can diverge in a red run — a pre-staged asset makes the integrity check pass while the wiring is still broken. State explicitly in the PR body which checks were genuinely red so reviewers don't misread the evidence.

Related: [[vendored-split-build-import-guard]]
