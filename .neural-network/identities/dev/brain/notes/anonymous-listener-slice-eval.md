---
tags: [tests, templates, frontend]
paths: ["plugins/spec-workflow/tests/**", "plugins/spec-workflow/templates/**"]
strength: 2
source: "#88 retro — third proven use (#71, #73, #88)"
graduated: false
created: 2026-07-08
---

To test anonymous addEventListener callbacks (no named function to regex-extract): slice the source between two grep-verified-UNIQUE literal substrings, eval the block against a stub environment, and drive real synthetic events end-to-end. Third proven use across the template's pointer/dblclick harnesses — the standard technique for this codebase.

Related: [[template-extract-anchor-check]] [[duplicate-with-agreement-pin]]
