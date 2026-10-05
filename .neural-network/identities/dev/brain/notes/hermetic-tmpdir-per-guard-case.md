---
tags: [tests, tdd, migration]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#64 (#62) retro"
graduated: false
created: 2026-07-07
---

Write migration-guard test cases (guard fires / override bypasses / neither path exists) as physically separate hermetic tmpdirs, never folded into shared setup — isolation makes each assertion's ownership obvious and surfaces message-text mismatches (case-sensitive greps) immediately instead of as confusing cross-case failures.

Related: [[old-path-repo-wide-sweep]]
