---
tags: [process, board, dispatch]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: 463
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Before briefing a dev on any picked issue, run `git log --all --grep="<issue-number>"` (and grep the code for the issue's key identifiers): FOUR issues in one night (#451, #453, #462, #463-core) turned out already shipped with the issue left open — stale-open issues whose fix landed under another task's commits or a local-route merge that never auto-closed them. The honest iteration for those is comment-evidence-and-close, not re-implementation; for #463 the dev's pre-implementation audit converted the dispatch into finding a REAL residual gap instead of duplicate work. Root discipline: `board.sh audit` reconciles merged-commit references at session close — run it; a skipped audit is how the board accumulates these.
