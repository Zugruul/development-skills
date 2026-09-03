---
tags: [security, input-validation]
paths: []
strength: 1
source: "PR#5 round 2 negative-offset finding"
graduated: false
created: 2026-07-07
---

Hostile-input guards must be SYMMETRIC: covering offset>size but not offset<0 left a per-request crash in the just-hardened surface. When adding a boundary guard, enumerate the whole input domain, not the case that bit you.
