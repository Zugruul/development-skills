---
tags: [frontend, api, debugging]
paths: ["plugins/spec-workflow/templates/**", "plugins/spec-workflow/scripts/**"]
strength: 1
source: "#75 retro"
graduated: false
created: 2026-07-08
---

A "rendering/grouping" UI bug may really be upstream data loss — the server only emitted (repo,role) combos that had notes, so the client had nothing to group; once the data contract carried the full set (repoRoles), the panel fix was almost incidental. Check what the API actually emits before redesigning the renderer. When a canonical list already exists (identity_lib.DEFAULTS), mirror it with a documented comment rather than importing across modules with side effects.

Related: [[trace-state-mutation-not-named-trigger]]
