---
tags: [review, testing, coverage]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: #344
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

"Function X is tested" is not evidence the FEATURE works: #344 shipped a queue chip whose pure renderer was unit-tested (renderQueueChip(2,...) correct) while the one real call site passed a hardcoded 1, and a transform-origin whose math was never asserted at all — both invisible because no test read the ACTUAL computed value or routed branch off the REAL call path. Review question that catches the whole class: "tested through which caller — and does that caller's test cover every input the acceptance criteria promise, not just the one the report demoed?" (The third face of the same defect: a type dispatch demoed only for 3D, silently wrong for image/video.)

Related: [[stub-shaped-blind-spots]] [[reproduce-before-verdict]]
