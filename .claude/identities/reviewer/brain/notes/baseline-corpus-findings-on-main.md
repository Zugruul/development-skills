---
tags: [review, verification, baseline]
paths: []
strength: 1
source: "Zugruul/development-skills#253"
confidence: direct
learned-from: GL-012 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

A live-corpus anomaly found during review (e.g. round-trip mismatches) is NOT a finding until the SAME check runs against main's version of the code (git show main:<path> into a scratch dir) and differs. 8/290 byte-level mismatches reproduced identically on main — pre-existing, not the diff's regression. Baseline-on-main before attributing.
