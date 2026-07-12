---
tags: [tooling, github]
paths: []
strength: 1
source: "retro"
learned-from: task 154 close
graduated: false
created: 2026-07-12
---


# gh 401 from a secondary worktree: retry once from the repo root

`gh` calls (pr comment/create) can fail 401 Unauthorized when invoked from a
secondary git worktree while the same command succeeds from the repository
root. Before treating a 401 as an auth outage, retry once from the repo root.
