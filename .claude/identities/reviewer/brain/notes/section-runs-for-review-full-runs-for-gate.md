---
tags: [review, testing, workflow]
paths: []
strength: 1
source: "Zugruul/development-skills#254"
confidence: direct
learned-from: GL-013 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

For review verification use the runner's --section filter (fast, attributable, avoids the 120s background dance); reserve full unfiltered runs for gate.sh, which requires them to record a valid pass. Also: cross-check every doc example glyph-by-glyph against the formatter's actual output — skimming for 'mentions the right pieces' misses composition-order errors.
