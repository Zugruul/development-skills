---
tags: [review, tooling]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-10
graduated: false
created: 2026-07-07
---

Before reporting a data-corruption-shaped finding, verify your own repro plumbing (echo vs printf, quoting layers) and reproduce through two different channels — an echo-mangled probe nearly filed a false JSON-validity finding that would have cost a full fix round. Related: [[reproduce-findings-two-pass]].
