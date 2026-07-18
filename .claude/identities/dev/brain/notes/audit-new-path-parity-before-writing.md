---
tags: [tdd, additive-features, code-review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#140 MEM-032 self-critique post-review"
graduated: false
created: 2026-07-18
---

Before writing a new code path that must UNION with / behave like an existing path (per a spec like "seed with the union of (a) and (b)... then rank as today"), read the existing path's equivalent block FIRST and audit every filter/early-return/edge-case it applies (graduated flags, defaults, missing-key guards) -- not just its happy-path logic. Match those exactly (including which pipeline stage a filter applies at) before writing the new block, rather than writing the new path's functional logic first and discovering the asymmetry only when review flags it.

Recurrence (MEM-032): the new hybrid-seed loop filtered graduated notes at seed time; the existing keyword-seed loop only filters them at emit time. A pre-writing parity audit of the existing block would have caught this before it needed a review round to surface.

Related: [[parity-check-new-vs-existing-path]] [[verify-fixture-isolates-intended-path]]
