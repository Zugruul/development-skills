---
tags: [state, teardown, ui]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

For any stateful start/stop pair, enumerate every path that leaves the state and check each undoes what entry did. Voice listening had four stop paths (manual, auto-stop-on-final, engine error, TTS interlock) and only the manual one tore down fully — leaving a hot mic with the indicator off. Factor one teardown function and call it from every exit.
