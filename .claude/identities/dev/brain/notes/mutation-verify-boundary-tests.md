---
tags: [testing, boundaries, mutation]
paths: []
strength: 1
source: "Zugruul/development-skills#254"
confidence: direct
learned-from: GL-013 retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

Every threshold/boundary test (budget, cutoff, limit) must be mutation-verified: invert the property in the source, rerun the section, confirm the assertions flip to FAIL, revert. It is the only way to know a boundary assertion isn't vacuously true — a boundary test that passes against the inverted source is testing nothing.
