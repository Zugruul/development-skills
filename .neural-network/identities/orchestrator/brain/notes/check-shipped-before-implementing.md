---
tags: [process, board, dispatch]
paths: ["**"]
strength: 2
source: ""
confidence: direct
learned-from: 479
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Before briefing a dev on any picked issue, run `git log --all --grep="<issue-number>"` (and grep the code for the issue's key identifiers): stale-open issues whose fix landed under another task's commits are common under local-route merges, and the honest iteration for those is comment-evidence-and-close. When history shows partial landing, the dev brief should target the residual gap explicitly. Standing prevention: `board.sh audit` at session close reconciles merged-commit references.
