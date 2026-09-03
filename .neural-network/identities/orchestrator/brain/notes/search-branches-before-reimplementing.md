---
tags: [process, recovery, git]
paths: ["**"]
strength: 1
source: "retro 3d-viewer recovery session"
graduated: false
created: 2026-07-23
---

When a human remembers a feature the mainline lacks, grep unmerged branches and worktrees BEFORE reimplementing (git branch -a + git grep <feature-text> <branch> -- <likely paths>). Recovered work rebased onto current mainline preserves original authorship and carries design lessons a reimplementation would silently lose — in one case the abandoned branch held a superseding CSS technique that fixed the freshly merged version.

Related: [[live-validation-is-loop-input]] [[batch-same-surface-bugs]]
