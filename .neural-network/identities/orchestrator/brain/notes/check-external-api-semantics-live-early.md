---
tags: [api, verification, review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#544 spec review"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

One small live query can settle what no stub can.

## What happened
- A reviewer could not tell whether `fieldValueByName` is case-sensitive without calling GitHub.
- One 1-point query showed it was: `Status` matched 30 of 30 items and `status` matched 0 of 30.
- Without that check, a differently cased field would have silently disabled WIP admission.

## What to do
- List the external behaviours a change depends on, and test each once live at low cost, early.
- Do this when the failure mode is silent or fails open.
