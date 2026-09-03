---
tags: [delegation, worktrees, tdd]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: #461
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

When a lane is write-blocked (worktree pin, sandbox), don't respawn and hope: have the blocked agent hand over EXACT patch text (unified diffs + the verification outputs it observed), then apply by relay — red test applied first and verified failing before the fix lands, commits authored as the dev with reviewer co-author via on-behalf flags. Zero-deviation application preserves TDD discipline, attribution, and the reviewed content. The blocked agent's derivation work is not wasted; only the mechanism changes.

Related: [[serialize-moves-behind-matching-gate]]
