---
tags: [git, process, recovery]
paths: []
strength: 1
source: "concurrency commits incident, resolved 2026-07-07"
graduated: false
created: 2026-07-07
---

When unreviewed-but-sound work accidentally lands on shared main: do NOT force-rewrite history to restore process purity — run the review post-hoc on the exact commit range and route findings to a follow-up PR. A dev agent that STOPS and asks before force-pushing is the behavior to reinforce.

Related: [[shared-checkout-hazard]]
