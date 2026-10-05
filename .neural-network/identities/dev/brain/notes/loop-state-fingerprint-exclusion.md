---
tags: [enforcement, tree-state]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-21
graduated: false
created: 2026-07-07
---

Every local loop-state file the workflow writes (pass markers, telemetry, feedback feeds) must be pathspec-excluded from the tree fingerprint in tree-state.sh — never rely on the consumer repo's .gitignore for enforcement correctness. Adding a new loop-state file means adding its exclusion + a no-gitignore regression test in the same change. Third instance of this class: gate-pass, then telemetry.jsonl. Related: [[lane-cwd-distrust]].
