---
tags: [briefing, verification, process]
paths: []
strength: 1
source: "PRV-002 -- --label addition initially missing, caught by direct grep, added on request"
graduated: false
created: 2026-07-15
---

A follow-up scope addition sent mid-task (e.g. via SendMessage while the agent is still working) can silently get missed if the agent already passed the point in its plan where that addition belongs -- it will report 'done' without it. Always independently verify a requested addition landed on the actual pushed branch (grep the real file) before accepting a 'done, added it' claim, even from an otherwise careful agent.
