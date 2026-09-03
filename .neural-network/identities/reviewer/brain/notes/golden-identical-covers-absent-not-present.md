---
tags: [review, additive-features, degrade-gracefully]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#140 MEM-032 review round 1"
graduated: false
created: 2026-07-18
---

A "golden-identical when absent/disabled" guarantee, even when verified as a genuinely shared code path (one `if` gate, not parallel logic), only covers the OFF/absent mode. The ON/present branch of an additive feature has no structural sharing with the pre-existing path to lean on — it needs its OWN explicit parity check against whatever existing path it is unioned/merged with, because that branch can diverge in edge-case handling (filter placement, tie-breaks, defaults) while still passing every "identical when absent" test.

Recurrence (MEM-032): confirmed sidecar-absence used a real `if os.path.exists(db_path):` single-branch gate (golden-identical held, verified). That gave zero coverage of the graduated-note filtering bug, which lived entirely inside the present-and-active branch.

Related: [[parity-check-new-vs-existing-path]]
