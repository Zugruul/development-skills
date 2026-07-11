---
tags: [perf, metrics, neural-view]
paths: ["plugins/spec-workflow/templates/neural-view.html", "plugins/spec-workflow/scripts/neural-view.py"]
strength: 1
source: "session retro 2026-07-10: neural-view perf increment"
graduated: false
created: 2026-07-10
---

UI performance work becomes autonomously iterable once the page self-reports: tabs POST live metrics (version, fps, per-section frame timings, sim state) to their dev server, GET /metrics + the CLI status command surface them, and a headless browser pointed at the page closes the loop — measure, change, live-reload, re-measure, no human screenshots. Pair with [[synthetic-corpus-perf-rig]] for load beyond real data.
