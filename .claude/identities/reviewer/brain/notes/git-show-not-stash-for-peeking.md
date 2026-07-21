---
tags: [review, git, read-only, shared-clone]
paths: []
strength: 1
source: "Zugruul/development-skills#253"
confidence: direct
learned-from: GL-012 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

To peek at another ref's version of a file during review, never git stash or checkout — use 'git show <ref>:<path> > scratch-file' (under the job tmp dir). Zero working-tree mutation, no classifier block, no risk to anyone's uncommitted state in a shared clone.
