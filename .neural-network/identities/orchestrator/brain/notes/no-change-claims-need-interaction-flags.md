---
tags: [briefing, orchestration]
paths: ["plugins/spec-workflow/skills/**"]
strength: 1
source: "#70 retro (dev feedback on the brief)"
graduated: false
created: 2026-07-08
---

A brief's "no X change needed" line reads as "nothing to check there" — when a known interaction exists (e.g. a downstream renderer that will double a prefix the fix introduces), the brief must flag it explicitly for the owning lane instead of asserting flat no-change. Verified-absence and unexamined-absence are different claims.

Related: [[pre-diagnose-before-brief]]
