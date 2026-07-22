---
tags: [review, verification, imports]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300 review
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

For "X reuses Y, no reimplementation" claims: grep the consumer for each symbol it claims to import, confirm each is a real definition in the provider, and check the CALL SIGNATURE at every call site against the real def (arg order/count) — docstrings and module comments assert intent, symbols prove it. For any defect CLASS found once (e.g. brace-group cd in sourced test sections), sweep the whole suite for the pattern so the verdict can say "confirmed absent suite-wide," not "absent where I looked."

Related: [[dual-path-fixture-proves-sharing]]
