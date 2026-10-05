---
tags: [review, git, worktrees, fail-silent]
paths: ["plugins/spec-workflow/scripts/brain.py"]
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

When a spec's failure-mode clause is implemented as a broad except-and-return-None, ask which caught cases are TRUE environment failures vs valid-but-unhandled layouts. A linked worktree's file-form .git is normal git, not a failure — yet it fell into the same catch-all as 'no git binary' and degraded silently. Whenever reviewing a 'read .git directly, no subprocess' fast path, test it from inside a linked worktree; also test the reviewer's OWN execution environment, not just the spec's enumerated failure list.
