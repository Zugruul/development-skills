---
tags: [review, repro, fixtures]
paths: []
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

When hand-rolling a repro that mirrors an existing test fixture, copy the fixture's EXACT setup steps instead of reconstructing from spec/docstring — fixtures encode gotchas the prose doesn't (e.g. mint stamps last-touched=today by default, which shadows a backdated created and makes a fixed code path look broken).
