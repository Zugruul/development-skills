---
tags: [concurrency, neural-view, servers]
paths: ["plugins/spec-workflow/scripts/neural-view.py"]
strength: 1
source: "session retro 2026-07-10: stale-template debugging"
graduated: false
created: 2026-07-10
---

Parallel agent sessions (build-loop worktrees) repeatedly start neural-view servers on the shared default port, each serving ITS OWN checkout's template — tabs silently render stale builds and the failure reads as "my fix didn't work". Mitigations now in place: the served page shows a version tag (chip: v X.Y.Z) so staleness is visible at a glance; for measurement work always use an env-scoped port+state (NEURAL_VIEW_PORT/NEURAL_VIEW_STATE). Structural fix worth considering: per-checkout default port derived from the repo path hash.
