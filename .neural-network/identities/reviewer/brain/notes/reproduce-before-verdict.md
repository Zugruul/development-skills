---
tags: [review, verification, empiricism]
paths: ["plugins/spec-workflow/**"]
strength: 2
source: "PR-close batch #438/#338/#441"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Never review a fix against its own commit message — reproduce the root cause AND the fix yourself, using the branch's REAL output, never a hand-written approximation (a mock proves your fix works; only real output proves theirs does). Verify the fix you recommend before recommending it — hand over "verified: these exact observations" instead of a suggestion the dev must re-derive. When a fix claims to close a class, enumerate the class and probe each member; the escapes that matter are never the first one tried.

Related: [[grep-for-the-third-site]] [[test-at-the-observed-layer]]
