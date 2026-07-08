---
tags: [debugging, flakes, concurrency]
paths: ["**"]
strength: 1
source: "#55 retro"
graduated: false
created: 2026-07-08
---

For a cross-instance race: go CONCURRENT early (sequential retries are nearly worthless — 15 solo runs missed what the first concurrent batch hit), and the moment you have ANY natural repro, convert it to a deterministic forced collision — iterating fixes against a 100%-reliable trigger is an order of magnitude faster than ~10% scheduling luck. Harness note: in backgrounded scripts prefer `find -delete` over bare `rm glob*` — zsh's nomatch kills the whole job silently on an empty glob.

Related: [[hotfix-repro-incident-sequence]] [[poll-own-children]]
