---
tags: [commits, changelog, ux]
paths: []
strength: 1
source: "human feedback 2026-07-26 (#418)"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Commit-message language is a product surface once a changelog pipeline renders bodies verbatim into UI: dense reviewer-facing prose becomes an unreadable changelog entry for the human. Write squash bodies as simple titles + human bullet lists (config knob commitSystemPrompt/commitConvention tracked #418) — the audience of a merge commit is the future changelog reader, not the code reviewer.

Related: [[brief-load-bearing-lines]]
