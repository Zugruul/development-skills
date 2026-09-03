---
tags: [css, stacking, layout]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "#399 retro"
graduated: false
created: 2026-07-25
---

backdrop-filter (like transform) makes an element a stacking context AND the containing block even for position:fixed descendants — any popover/dropdown/overlay child of a blurred HUD panel is trapped at the panel's own z-index and cannot paint above sibling panels, and overflow:hidden on a positioned ancestor clips absolutely-positioned descendants too. Popovers that must appear atop other panels live at BODY level and mirror their anchor's box with position:fixed arithmetic (the #ast-switch-dropdown pattern); leaving one inside the panel is the exact defect class (#403 digest panel). Links: [[compound-selector-for-shared-base]], [[render-states-before-asserting-layout]].
