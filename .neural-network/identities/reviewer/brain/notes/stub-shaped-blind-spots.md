---
tags: [review, testing, stubs]
paths: ["plugins/spec-workflow/templates/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: #474
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

A test harness that stubs a side-effectful function as a no-op counter (e.g. `stopStt = () => { calls++ }`) structurally CANNOT catch bugs living in that side effect — the #474 double-terminal-span bug survived a passing suite precisely because the stub couldn't express stop()'s synchronous flush-through-onResult. Before trusting a passing test around a claimed fix, ask: could this harness's stubs even EXPRESS the failure mechanism? If the mechanism is a side effect the stub elides, extract the REAL production functions into a standalone repro and drive them together end to end — reading the stubbed test and seeing green would have produced a false APPROVE.

Related: [[reproduce-before-verdict]] [[tested-through-which-caller]]
