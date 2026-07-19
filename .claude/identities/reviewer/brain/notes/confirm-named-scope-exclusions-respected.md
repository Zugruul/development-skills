---
tags: [review, scope, process]
paths: ["**"]
strength: 1
source: "PR#128 MEM-004 retro"
graduated: false
created: 2026-07-18
---

When a design doc explicitly names something as OUT of scope and points at the specific future task that owns it (not just "not now" but "not now, owned by task Y"), the review should explicitly confirm that boundary was RESPECTED -- not just that the in-scope change is correct. An unscoped "helpful" cleanup while a dev is already touching adjacent messy code is a common failure mode; confirming the excluded area was left alone is a cheap check (one `diff`/`grep` against the specifically-named excluded area) worth adding to the review routine whenever a design doc names an explicit deferral.

Recurrence (MEM-004 review): design doc explicitly deferred cleaning up a `.gitignore` file's pre-existing duplicate lines to a named future task (MEM-012) -- reviewer explicitly confirmed those lines were untouched in the diff, not just that the one intended line was removed correctly.

Related: [[note-dont-gate-on-unrelated-findings]]
