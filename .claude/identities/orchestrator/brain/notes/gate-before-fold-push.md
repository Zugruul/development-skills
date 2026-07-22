---
tags: [gate, spec-delta, fold, main-hygiene]
paths: ["docs/spec-deltas/**", "SPEC*.md"]
strength: 1
source: ""
confidence: direct
learned-from: GL-021 #256 wrap-up
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Post-merge orchestrator commits (spec-delta folds, retro/feedback commits) pushed to main WITHOUT a gate run turned main red: the GL-050 fold moved docs/spec-deltas/GL-050.md to applied/gl-300.md while a kb-seed test asserted the pre-fold path. Two rules: (1) run the gate before pushing ANY orchestrator commit to main, folds especially — a fold changes tracked files a test may pin; (2) when reviewing new tests, reject assertions on stage-specific file locations that a later workflow step legitimately moves — assert either-location or content. Mechanical fix tracked as a backlog bug.

Related: [[board-moves-before-branch-delete]]
