---
tags: [merge, permissions]
paths: []
strength: 1
source: "retro 2026-07-11, feedback item"
graduated: false
created: 2026-07-11
---

A project's own 'auto-merge enabled' configuration does not guarantee the runtime environment will allow fully autonomous merging. A host-level safety layer can independently require a human in the loop when a PR's only approval came from a spawned sub-agent, regardless of project config -- and this may only be discoverable by attempting the merge. Treat a denial here as a normal, expected checkpoint requiring a human decision, not a bug to route around or fight.
