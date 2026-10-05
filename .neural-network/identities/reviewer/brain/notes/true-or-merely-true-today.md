---
tags: [review, invariants, durability]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #340"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Ask of every rule the spec states in absolute terms: is this invariant TRUE (pinned by construction) or merely true TODAY (a fact about current callers)? An enforced-but-unpinned invariant decays silently the first time someone adds a call site — the same failure shape as checks that LOOK enforced and aren't, arriving from the opposite direction. The cheap durable fix is a structural guard pinning the property itself.

Related: [[one-time-assertion-as-live-gate]]
