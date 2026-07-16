---
tags: [scope, tdd, linting]
paths: []
strength: 1
source: "task #177 (CDX-005)"
graduated: false
created: 2026-07-16
---

A task's stated file list/count (from when it was written) can go stale as the codebase moves -- when the task's actual acceptance criterion is a property ("the linter passes on every SKILL.md"), re-derive the real scope by running the actual check against everything, don't just fix the named files and stop.

Why: #177 (CDX-005) was scoped to 5 named skill descriptions with angle-bracket violations. Running the validator against every skill in both plugins (not just the named 5) found a 6th (peer-review/SKILL.md) that merged with the same defect after the task was originally written. Trusting the stale list would have shipped a known-detectable violation.

How to apply: when a task names specific files as the scope but the underlying acceptance criterion is really a property over a larger set (every file of a kind, every entry in a directory), run the real check over the full set before declaring done -- the named list is a snapshot, not a boundary.
