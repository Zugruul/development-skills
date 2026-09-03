---
tags: [contracts, invariants, refactoring]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #424"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Before changing a previously-reviewed function's behavior, enumerate the guarantees its EXISTING callers and tests rely on — not "does my change make my case work" but "does it preserve every promise, including ones to callers I'm not looking at." A docstring sentence like "cache key deliberately carries no repo root" is a decision record, not an oversight; needing to invalidate one is the HEADLINE of your report, and the moment to look harder for a design that avoids touching the promise at all.

Related: [[resolve-into-the-keyed-value]]
