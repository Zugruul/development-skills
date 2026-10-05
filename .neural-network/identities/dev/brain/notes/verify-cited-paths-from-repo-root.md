---
tags: [briefing, verification]
paths: []
strength: 1
source: "retro"
learned-from: PR #153 retro
graduated: false
created: 2026-07-11
---


# Verify cited files from the repo root before reporting them missing

When a brief cites a spec/doc by path, check its existence from the repo root
(`ls <root>/<path>`), not via a shallow find/grep from wherever your cwd
happens to be — a search from the wrong directory produces a false "file does
not exist" that then propagates into reports and PR bodies. If it's genuinely
absent, say where you looked; if the brief carries the requirements inline,
treat those as authoritative and flag the discrepancy instead of guessing.
