---
tags: [delegation, recovery, git]
paths: ["**"]
strength: 1
source: "retro AST-024 (salvage)"
graduated: false
created: 2026-07-24
---

When an implementation agent stalls or goes idle without a report, inventory the working tree INCLUDING untracked files (git status --short shows ?? lines — do not head-truncate them away) before re-briefing, reassigning, or rewriting anything. A stalled agent may have completed the entire task — implementation, new modules, tests, even a spec delta — and failed only at the commit/report step. The salvage: set the impl aside, commit its tests red with observed fast proofs (imports, defaults, grep-0) if the full red run hangs, restore, commit impl under the agent's authorship. Cheaper than any rebuild and preserves the TDD trail.

Related: [[search-branches-before-reimplementing]] [[mode-elastic-loop]]
