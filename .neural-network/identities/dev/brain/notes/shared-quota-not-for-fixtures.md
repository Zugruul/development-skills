---
tags: [rate-limits, shared-resources]
paths: ["**"]
strength: 1
source: "#91 retro (declined deliberate GraphQL exhaustion)"
graduated: false
created: 2026-07-08
---

Never deliberately exhaust a shared, live rate limit (or any shared-ceiling resource on a real credential) just to capture a "complete" fixture set — that optimizes one task's completeness at the cost of every concurrent agent on the same account. Document the uncaptured boundary case honestly (what you have, what's missing, why) and note the safe capture recipe for someone with a disposable credential. Dedicated sandbox tokens exist precisely so this tradeoff never has to be made against live systems.

Related: [[capture-dont-transcribe]]
