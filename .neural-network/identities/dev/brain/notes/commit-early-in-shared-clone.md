---
tags: [git, concurrency, shared-clone, safety]
paths: []
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 retro (root cause confirmed: orchestrator checkout -- during docs extraction)
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

In a shared clone where the orchestrator also runs git commands, an uncommitted edit is the only vulnerable state — an orchestrator 'git checkout -- <file>' (e.g. cleaning up after extracting someone else's changes) will silently discard it while the Edit tool reported success. Commit early and often on the task branch; multiple uncommitted edits accumulated across tool calls are one restore away from vanishing.
