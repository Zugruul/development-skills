---
tags: [testing, budget]
paths: []
strength: 1
source: "PR#4 review round 2 self-correction"
graduated: false
created: 2026-07-07
---

When asserting output-length guarantees, compare rstrip-ed captured stdout — print() appends a trailing newline that is not budgeted content. I false-positived my own overshoot repro on this.
