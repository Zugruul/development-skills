---
tags: [brain.py, refactor, graph, reuse]
paths: ["plugins/spec-workflow/scripts/brain.py"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

brain.py's hop-spread traversal is now single-sourced in `_spread_activation(links, seed_activation, max_hops, mutate, on_cross)` — the two per-caller differences (bump fires/last or not; emit hop events or not) are parameterized via the `mutate` flag and `on_cross` callback, never inline branches. Any third consumer (e.g. a `path` BFS variant, GL-021) should reuse this function and push its own side effects through the callback, not copy the loop. Same pattern for card rendering: `_format_header_line` (GL-013) is the ONLY place slug/strength/confidence/tally/contested/stale compose into one line — call it, never re-derive the string, and prove sharing with a same-fixture both-paths diff test.

Related: [[verify-fixture-isolates-intended-path]]
