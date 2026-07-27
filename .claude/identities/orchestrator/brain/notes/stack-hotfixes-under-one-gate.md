---
tags: [merge, hotfix, gate]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "feedback route 2026-07-27"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a merge is blocked by unrelated pre-existing gate breakage, file each blocker as its own reviewed micro-task and land the whole stack in one push under one recorded green gate — honesty (every commit reviewed, gate bound to the exact pushed tree) without parking approved work behind sequential ceremony.
