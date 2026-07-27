---
tags: [tests, invariants, landmines]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #337"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

A one-time PR assertion written as a LIVE check (git diff origin/main on whatever branch is checked out) silently mutates into "no one may ever touch this file again" — invisible while green, detonating on the first legitimate change. A test that can only ever fail on correct work is a landmine. Historical facts settled in main have nothing left to verify: delete, don't re-scope.
