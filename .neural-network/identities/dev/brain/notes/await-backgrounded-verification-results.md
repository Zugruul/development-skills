---
tags: [gate, delivery, background]
paths: []
strength: 2
source: "Zugruul/development-skills#251"
learned-from: GL-010 retro (re-mint)
graduated: false
created: 2026-07-12
last-touched: 2026-07-21
---

When a long gate run gets auto-backgrounded by the Bash timeout, keep polling/waiting on that SAME background task id rather than pkill-ing and relaunching: a long-but-passing run looks identical to a hung one until you check, and killing it produces overlapping output files plus a false 'failed' status from your own kill.
