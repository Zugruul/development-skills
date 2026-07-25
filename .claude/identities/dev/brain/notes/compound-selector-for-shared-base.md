---
tags: [css, specificity]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "#330 retro"
graduated: false
created: 2026-07-25
---

When overriding sizing/layout on an element that carries a shared base class (.note-window, .hud, ...) plus a new feature-specific class, write the override as the compound selector (.base.feature{...}) from the start — never a bare single-class rule. A bare rule is an equal-specificity cascade tie decided by source order (dead the moment the base rule sits later), while the compound is specificity-correct and immune to reordering. Where a rule LIVES is a proximity choice; whether it WINS is a specificity question — check the shared class's declarations for overlapping properties before trusting source order. Links: [[render-states-before-asserting-layout]].
