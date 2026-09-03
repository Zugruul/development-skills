---
tags: [caching, keys, design]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #424"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a bug reads "this key/cache/comparison doesn't account for X", the tempting fix is adding X to the key — but first check whether X can be resolved INTO the value being keyed, upstream. Substituting the repo root into the argv before the cache ever sees it made the existing key correct by construction, kept the checker repo-unaware, and left the landed contract untouched.
