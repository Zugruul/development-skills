---
tags: [process, review, hotfix]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: 490
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

When the human's do-it-now directive makes the orchestrator author code directly (no dev agent), the two independent review passes stop being ceremony and become the ONLY second pair of eyes — run them anyway, in parallel with the gate so they cost no wall-clock. Concrete yield on one small self-authored hotfix: 4 real findings self-review missed (a stranded UI artifact on an untouched stop path, a CSS specificity loss the author's own comment claimed worked, a missing staleness guard mirroring the file's established pattern, an undocumented rebuild tradeoff). Tell the reviewers explicitly that the orchestrator wrote it and their independence is the only check — it sharpens the review.
