---
tags: [ttl, cache, clock, time]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #337 review round 1"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

TTL caches must default to time.monotonic, never time.time: a backwards wall-clock jump (NTP) makes now-cached_at negative, which satisfies the less-than-ttl test, pinning a stale verdict indefinitely — silent, unloggable, and invisible to tests because tests inject their own clock. The codebase precedent (adapters.py) already used monotonic three files over.
