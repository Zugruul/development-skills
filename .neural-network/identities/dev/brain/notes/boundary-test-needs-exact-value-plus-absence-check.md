---
tags: [testing, tdd, boundaries]
paths: ["**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

For any inclusive/exclusive boundary test (a `--since`/threshold/date filter), the fixture must include a data point EXACTLY ON the boundary value, with a distinguishing marker in the fixture data itself, PLUS an explicit assertion that a value on the excluded side is absent. Testing only "a value clearly after the boundary is included" passes even with an off-by-one in the wrong direction -- "before" and "after" alone cannot distinguish `>` from `>=`.

Recurrence (MEM-002): the --since boundary test used three months, with the MIDDLE month set as both the fixture data's exact --since value AND carrying a distinguishing marker ("february item (boundary)") in its summary, plus an explicit check_absent on the excluded earlier month -- this is what let two independent reviewers hand-trace and confirm the exact `<` vs `<=` semantics rather than just observing "yes, later stuff shows up."

Related: [[trace-boundary-operators-by-hand]]
