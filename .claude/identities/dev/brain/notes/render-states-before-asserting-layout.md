---
tags: [css, layout, verification]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "#397 retro"
learned-from: review rounds 2-3
graduated: false
created: 2026-07-24
---

When a CSS change alters how a box computes size (height <-> min-height <-> max-height <-> flex-basis) on an element that has state-modifier selectors (.folded/.collapsed/[hidden]) or that JS measures via offsetHeight/scrollHeight: audit EVERY modifier selector and EVERY measurement call site for interaction effects, and verify by actually rendering each state at a short and a tall viewport. Never assert layout behavior in a comment from spec-reasoning alone — offsetHeight excludes overflow:visible spill, min-height floors every state including modifiers, and both are easy to get backwards on paper. A property swap is not a drop-in replacement until each state is measured.
