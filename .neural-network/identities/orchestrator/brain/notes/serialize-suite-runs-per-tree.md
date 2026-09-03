---
tags: [gate, concurrency, testing]
paths: ["plugins/spec-workflow/tests/run-tests.sh"]
strength: 1
source: "retro AST-020 (feedback item 3)"
graduated: false
created: 2026-07-22
---

Never run two full-suite/gate invocations concurrently in the same working tree — interleaved or partially captured output wastes a diagnosis round on phantom failure counts. One tree, one suite run at a time; parallel lanes get their own worktrees and their own runs.
