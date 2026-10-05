---
tags: [git, worktrees, testing, fail-silent]
paths: ["plugins/spec-workflow/scripts/brain.py"]
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

Any code that reads .git/ directly (not via a git subprocess) MUST be fixture-tested from inside a 'git worktree add'ed directory, not just a plain 'git init'ed one: .git is a directory in one and a FILE ('gitdir: <path>', with refs/packed-refs in the commondir) in the other — and this repo's own build lanes run in linked worktrees, so the file-form is the DEFAULT execution environment here. Under a fail-silent contract the miss produces zero errors and quietly disables the feature.
