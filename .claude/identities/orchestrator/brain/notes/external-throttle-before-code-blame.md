---
tags: [performance, diagnosis]
paths: []
strength: 1
source: "#399 session perf incident"
graduated: false
created: 2026-07-25
---

Before hunting a rendering perf regression in code, rule out external pacing: measure raw rAF cadence on the page with ALL app content hidden (empty page still slow = the browser is throttling, not the code) and check power state (Chrome Energy Saver activates at <=20 percent battery and quarters rAF to ~30fps; macOS Low Power Mode similar). The page's own cheap frame timings (sim/vis/draw ~1ms at 30fps) are the tell that cadence, not work, is the bottleneck.
