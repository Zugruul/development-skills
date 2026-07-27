---
tags: [verification, ui, browser]
paths: []
strength: 1
source: "#431/#433/#434 2026-07-27"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

For template/UI merges, drive the REAL page before the dance: a per-branch server instance + browser automation verifying the actual behavior (render output, gesture math, first-paint layout). This is the only gate that catches harness-vs-browser divergence — module scoping (#431), WebKit compact layout (#434) — and each divergence found also hardens the stub to the real contract so the class dies.

Related: [[ping-gated-lane-sequencing]]
