---
tags: [review, verification, subprocess]
paths: []
strength: 1
source: "#408 review"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

To verify claims about missing-binary behavior when your box HAS the binary, build a mirror PATH containing every binary EXCEPT the one in question and re-run the real test section under it — a plain local pass proves nothing about the binary-less environment. This settled #408's crux (does the selection test tolerate a 502?) empirically.

Related: [[reproduce-claimed-bug-fix-before-and-after]]
