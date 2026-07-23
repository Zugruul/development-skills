---
tags: [review, tdd, verification]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "retro 373 (reviewer interview)"
graduated: false
created: 2026-07-22
---

Never take a red-first commit message's failure claim on faith: extract the pre-fix file into a scratch copy (git show base:path), rerun the specific test there, and confirm it passes at HEAD. This catches tests that never genuinely failed and fixes that pass coincidentally. Pair it with checking every path the fix touches but does not test — a fix is often correct on its tested path and silently widened on the untested one.
