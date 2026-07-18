---
tags: [review, parity, additive-features]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#140 MEM-032 review round 1"
graduated: false
created: 2026-07-18
---

When a task adds a new path that must UNION with / degrade to an existing path (per spec text like "seed with the union of... then rank as today"), diff the new code block against the analogous existing block filter-by-filter and stage-by-stage — not just read the new block in isolation and ask "does this look right."

Recurrence (MEM-032 review): the hybrid embedding-seed loop filtered graduated notes BEFORE they entered `activation`, while the pre-existing keyword-seed loop only filtered them at the final emit stage (letting them still spread via link hops). Same net output in the common case, different behavior once a second consumer (link-spreading) reads the intermediate state. The spec prose ("rank as today") never mentions this filter placement explicitly — it only surfaces by reading both blocks side by side and hunting for filters/early-returns present in one but not the other.

Related: [[golden-identical-covers-absent-not-present]] [[audit-new-path-parity-before-writing]]
