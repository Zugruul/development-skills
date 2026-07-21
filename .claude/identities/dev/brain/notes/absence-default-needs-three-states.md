---
tags: [frontmatter, cli, defaults, state]
paths: ["plugins/spec-workflow/scripts/brain.py"]
strength: 1
source: "Zugruul/development-skills#253"
confidence: direct
learned-from: GL-012 retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

When a frontmatter field's default is represented by key ABSENCE, the write path needs THREE states, not two: explicitly set, explicitly cleared back to default, and never-touched (inherits what the note already had). Collapsing omitted-flag into write-nothing silently downgrades previously-set values — exactly the asymmetric upgrade/downgrade bug class the no-silent-downgrade requirement exists for.
