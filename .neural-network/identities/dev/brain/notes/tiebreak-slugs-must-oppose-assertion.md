---
tags: [tests, ranking, fixtures]
paths: ["plugins/spec-workflow/scripts/brain.py", "plugins/spec-workflow/tests"]
strength: 1
source: "Zugruul/development-skills#251"
learned-from: GL-010 retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

In cmd_recall, ties in activation are broken alphabetically by slug. An ordering assertion between two fixture notes can pass by pure alphabetical luck even when the feature under test does nothing. Name fixture slugs so the alphabetical tiebreak favors the WRONG note (e.g. 'aaa-old-note' should be the one that must LOSE), forcing the assertion to pass only when the real mechanism produces the win.
