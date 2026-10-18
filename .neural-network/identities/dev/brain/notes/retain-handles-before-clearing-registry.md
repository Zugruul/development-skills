---
tags: [lifecycle, tests, threads]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#530 retro: saved worker references make shutdown assertions substantive"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Preserve evidence across cleanup

Capture references to owned threads or processes before shutdown clears their registry. After stopping, check those saved handles directly; `all(...)` over an empty registry proves nothing about whether the original workers exited.

## Pair the checks

Keep an independent before/after resource census as well. Saved handles prove the known workers stopped; the census catches additional owned resources the registry did not expose.

Related: [[poll-own-children]] [[sanity-check-fix-against-broken-code]]
