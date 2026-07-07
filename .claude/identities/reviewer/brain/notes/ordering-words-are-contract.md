---
tags: [review, spec]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-18
graduated: false
created: 2026-07-07
---

"Before/after" sequencing words in a spec are testable contract, not prose. When a spec mandates an order between two side effects, verify the code matches even if the final state is order-independent (the difference only shows on a mid-execution crash), and require a static ordering assertion so it can't regress. Related: [[named-attack-class-briefs]].
