---
tags: [review, tests, regex]
paths: ["plugins/spec-workflow/tests/**"]
strength: 2
source: "PR#69 (#68) retro — recurrence"
graduated: false
created: 2026-07-07
---

A test guard built on a regex/extraction can silently no-op against the real artifact it claims to cover (minified syntax, wrong anchors, empty match). Before crediting the guard as coverage, run its exact extraction against the actual file and confirm the matched content's length/shape — an empty or truncated match means the test passes vacuously.

Related: [[recompute-hashes-never-eyeball]] [[red-commit-worktree-verify]]
