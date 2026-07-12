---
tags: [gate, debugging]
paths: []
strength: 1
source: "retro"
learned-from: PR #153 retro
graduated: false
created: 2026-07-11
---


# A red gate is not necessarily your change

Before assuming your diff broke a red gate, `git log -- <failing file>` on the
specific failing check: a pre-existing convention gap in an unrelated file
(e.g. a test file merged earlier without a required guard) fails the same
gate. Fix it as a separate, clearly-labeled commit — it blocks recording any
pass — but never let it expand the task's scope beyond that one unblock.

Related: [[unassumed-full-pipeline-repro]]
