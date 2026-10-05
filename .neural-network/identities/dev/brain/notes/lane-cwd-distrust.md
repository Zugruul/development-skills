---
tags: [concurrency, git]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 E1 iteration
graduated: false
created: 2026-07-07
---

In parallel lanes, your shell cwd can silently reset between tool calls to ANOTHER lane's worktree. Use `git -C <abs path>` or `cd <abs path> &&` in the SAME call for every command, verify location before any write, and check `git status` before every commit so only intended files land. Related: [[bash32-empty-array-set-u]].
