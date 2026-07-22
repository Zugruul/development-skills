---
tags: [tests, fixtures, brain.py, determinism]
paths: ["plugins/spec-workflow/scripts/brain.py", "plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

For hand-computed expectations against links.json (activations, sort order), WRITE the fixture links.json directly with a small helper — building it through real `mint`/`recall` calls is non-deterministic for this purpose because mint pins weight=0.5/fires=0 and recall mutates as it reads. Put the arithmetic in a comment next to the assertion (e.g. HOP_DECAY(0.5) × weight 0.9 = 0.4500) so off-by-rounding and sort-direction mistakes are visible at review. Keep the graph a minimal star (hub→a, hub→b, no second hop) so a wrong sort/limit cannot hide behind a generous fixture.

Related: [[verify-fixture-isolates-intended-path]] [[batch-red-across-surfaces]]
