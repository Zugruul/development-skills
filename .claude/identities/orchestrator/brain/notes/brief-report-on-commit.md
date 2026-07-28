---
tags: [briefing, delegation]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: 2026-07-28-wave
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Dev agents default to holding their report until the full gate finishes, then idle silently if it is slow — three nudges across two lanes in one wave. Put it in the brief: report the moment commits land (files, red/green evidence, decisions made), send the long-running gate's result line separately when it exits, and say "blocked/incomplete" the instant that becomes true. An honest partial report always beats silence; the orchestrator can start read-only review in parallel with a running gate.

Related: [[relay-apply-on-behalf]]
