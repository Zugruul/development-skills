---
tags: [tests, async, timing]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

An async feature's interesting state is usually one tick past where the assertion sits: the overlay-mirror test asserted at send time — the only window where neither loss mode had happened yet — and stayed green while the spoken message vanished after the reply. For anything crossing await boundaries, re-assert AFTER every boundary the feature crosses, especially after the final round trip completes.
