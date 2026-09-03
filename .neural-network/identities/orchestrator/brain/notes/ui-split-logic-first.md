---
tags: [iterative-ui, briefing, process]
paths: ["plugins/spec-workflow/templates"]
strength: 1
source: "retro AST-021"
graduated: false
created: 2026-07-23
---

When iterative-UI mode gates a task, split the brief: the dev builds EVERY behavior with placeholder styling and named restyle-hook classes (testable, reviewable, mergeable), while the visual design goes to the human as concrete options. The reviewed logic can merge on explicit human direction with the restyle as a follow-up round on the same issue — the epic never idles waiting on aesthetics, and the restyle lands as a pure CSS/markup pass over stable hooks.

Related: [[mode-elastic-loop]] [[batch-same-surface-bugs]]
