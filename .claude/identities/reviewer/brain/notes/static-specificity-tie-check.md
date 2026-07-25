---
tags: [css, review, specificity]
paths: []
strength: 1
source: "#330 retro"
graduated: false
created: 2026-07-25
---

When a diff layers a new class onto an element already carrying a shared class family (note-window/media-window/hud...), run a static specificity-tie check on every property the new rule sets: grep the co-classes' rules for the same property and compare specificity then source order. A single-class rule with an equal-specificity same-property co-class rule LATER in source is dead code — flag it with zero browser work. Reserve headless computed-style measurement for genuinely layout-dependent questions (viewport math, wrapping, off-screen recovery) or for unarguable evidence in the report. Links: [[measure-geometry-not-strings]], [[stub-harness-blindspot]].
