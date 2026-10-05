---
tags: [board, tooling]
paths: ["plugins/spec-workflow/scripts"]
strength: 1
source: "retro 2026-07-11, feedback item"
graduated: false
created: 2026-07-11
---

Prefer the repo's own in-tree copy of a script over a globally-installed plugin-cache copy whenever the current repo IS that plugin's own source. The cached copy can lag the in-tree version substantially (different internal architecture, different resolved config/ids for the same live resource) and produces misleading, hard-to-diagnose failures rather than an obvious version-mismatch error. Always double-check which path is actually being invoked before trusting a confusing failure.
