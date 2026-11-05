---
tags: [shell, errors, review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#544 review round 2"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A new return code is only finished when every caller has been read.

## What happened
- A helper gained return code 4 for a failed read, to stop failures being reported as rate limits.
- Two callers were updated. A third still treated any nonzero as "queue it", so a broken token still looked like a rate limit, with exit 0.

## What to do
- Grep every caller of the function before committing a new return code.
- Add a test for each caller, not only the first one that motivated the change.

Related: [[stderr-suppression-hides-evidence]]
