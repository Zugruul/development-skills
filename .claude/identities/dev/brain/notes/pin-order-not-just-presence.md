---
tags: [testing, tdd, rendering]
paths: []
strength: 1
source: "#404 review round 1"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Substring-presence checks do not pin ORDER: when a spec declares a fixed rendering sequence (group order, section order), assert relative line positions explicitly — a mutation swapping the order passed the whole suite until the reviewer caught it. Validate such a test by mutating the implementation (swap the order), confirming red, then reverting.

Related: [[sentinel-needs-own-render-branch]] [[copy-exact-strings-tests-assert-against]]
