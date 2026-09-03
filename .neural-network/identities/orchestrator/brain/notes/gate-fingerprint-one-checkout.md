---
tags: [gate, worktree, process]
paths: []
strength: 1
source: "loop-feedback 2026-07-29 (485 close)"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A tree-fingerprint gate and the hook that enforces it must look at the SAME tree. A loop that lands commits on main by cherry-picking from a session worktree lets the two trees drift (release bots, changelog regens), so recorded passes chase a moving target -- two full gate runs were burned this way. Either pin gate runs AND board moves to one checkout, or sync the mirror to byte-identical content (compare 'git rev-parse HEAD^{tree}') immediately before recording the pass.
