---
tags: [css, template, review]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: ""
confidence: direct
learned-from: 490
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A CSS border/font/background SHORTHAND on a higher-specificity selector silently resets the longhand you set elsewhere: `.ast-chat-row[data-role="user"]{border:1px solid ...}` (0,2,0) sets border-style:solid and beats a bare `.ast-chat-pending{border-style:dashed}` (0,1,0) regardless of source order — cascade resolves per property by specificity. When layering a state class onto an attribute-selected base, write the compound selector (`.base[data-x].state{...}`) and verify with COMPUTED style in a real browser, never by reading source order. Found live: the pending bubble's "dashed edge" never rendered while its comment claimed it did.

Related: [[comments-deserve-code-scrutiny]]
