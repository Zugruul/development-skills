---
tags: [workflow, concurrency, merge, wip]
paths: ["**"]
strength: 1
source: "retro 2026-07-21 GL epic E0"
graduated: false
created: 2026-07-21
---

Do not pick a new task while the session's previous PR is unmerged, even when the WIP limit allows it — stacked squash-merges accumulate rebase debt, conflict risk, and (see [[stacked-prs-retarget-before-delete]]) unrecoverable PR closures. The human explicitly demanded merge-gated serial delivery; mechanical enforcement is tracked as a board item (workflow serial mode).

Related: [[stacked-prs-retarget-before-delete]]
