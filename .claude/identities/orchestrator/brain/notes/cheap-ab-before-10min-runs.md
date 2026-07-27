---
tags: [debugging, efficiency, ab-testing]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #437 investigation"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Before burning 10-minute full-suite runs on a theory, find the 30-second direct repro: simulating the suspect condition against the single failing command (bloated TMPDIR vs scaffold: 30s, disproved a session-old hypothesis; PYTHONPATH vs scaffold: 5s, proved the root cause with a full traceback). Full-suite bisection is the last resort, not the first move.

Related: [[discriminator-over-hypothesis]]
