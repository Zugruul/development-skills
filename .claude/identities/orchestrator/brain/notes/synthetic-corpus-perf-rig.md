---
tags: [perf, testing, neural-view]
paths: ["plugins/spec-workflow/scripts/neural-view.py"]
strength: 1
source: "session retro 2026-07-10: neural-view perf increment"
graduated: false
created: 2026-07-10
---

Scale testing needs a disposable rig: an isolated server instance (env-scoped state + non-default port), a generated corpus at 10x-100x with REALISTIC topology (local links + hubs — random long-range links create unsatisfiable spring systems that thrash forever and mislead tuning), and a headless Chrome probe reporting via [[ui-perf-metrics-loop]]. Tear it all down after. Watch for the data pipeline (scan time, payload size) becoming the wall before rendering does.
