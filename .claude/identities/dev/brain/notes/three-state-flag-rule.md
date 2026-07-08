---
tags: [cli, ux, errors]
paths: ["**"]
strength: 1
source: "#96 retro (explicit-empty --section= -> exit 2, upheld by review)"
graduated: false
created: 2026-07-08
---

A flag has THREE states, not two: absent -> default; present and valid -> apply; present but empty/malformed -> ERROR loud (nonzero + actionable message listing valid values). Silent degradation to the no-flag default is acceptable only when that default is what the user would have wanted anyway; if the fallback contradicts why they reached for the flag (e.g. --section= silently running the FULL suite the flag exists to avoid), error instead.
