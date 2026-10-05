---
tags: [css, units, template]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: ""
confidence: direct
learned-from: #344
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

The moment a CSS-length string your own code set (e.g. win.style.left = "26vw") gets fed back into arithmetic anywhere downstream, parseFloat silently returns the bare number in the WRONG unit (26, treated as px) — no error, no test failure unless something pins the computed value; it surfaces only as visually-wrong geometry a human must eyeball (#344's entrance origin was off by hundreds of px). Rule: compute positions in the unit you will consume them in (real px from innerWidth/getBoundingClientRect) and store those; never round-trip your own CSS strings through parseFloat. When reviewing, any parseFloat(el.style.*) is a flag.

Related: [[tested-through-which-caller]] [[stop-can-flush-synchronously]]
