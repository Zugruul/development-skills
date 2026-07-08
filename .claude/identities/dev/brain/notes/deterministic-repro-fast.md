---
tags: [debugging, flakes, concurrency]
paths: ["**"]
strength: 2
source: "#97 retro — recurrence (seeded-5812 forcing function)"
graduated: false
created: 2026-07-08
---

For a cross-instance race: go CONCURRENT early, then convert any natural repro into a deterministic forcing function — seeding the entropy source identically across processes (RANDOM=42) turned a scheduling-dependent flake into a 100%-repeatable proof on the first try. Harness corollary: port allocation under concurrency defaults to disjoint-by-construction (PID-sliced bands) from day one — the TOCTOU family (#8→#55→#67→#97) recurs whenever entropy is per-process-blind. In backgrounded scripts prefer find -delete over bare rm glob*.

Related: [[hotfix-repro-incident-sequence]] [[poll-own-children]]
