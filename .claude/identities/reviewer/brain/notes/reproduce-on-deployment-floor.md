---
tags: [review, portability]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-15
graduated: false
created: 2026-07-07
---

Green-on-host is not green-on-target. When a construct looks version-sensitive, identify what the test HOST provides beyond the deployment floor (interpreter version, optional installed deps like PyYAML, shell version) and reproduce on the floor. A newer PATH interpreter masked a hard crash that shipped through a green suite. Related: [[reproduce-findings-two-pass]], [[named-attack-class-briefs]].
