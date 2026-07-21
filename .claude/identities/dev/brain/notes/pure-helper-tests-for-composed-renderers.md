---
tags: [testing, rendering, helpers]
paths: ["plugins/spec-workflow/scripts/brain.py"]
strength: 1
source: "Zugruul/development-skills#254"
confidence: direct
learned-from: GL-013 retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

When a rendering helper composes several independently-optional signals into one line, unit-test the helper as a PURE FUNCTION (direct calls enumerating each optional part), not only through the CLI — it isolates composition/ordering bugs from budget/tier mechanics and makes 'each part independently optional' trivially enumerable.
