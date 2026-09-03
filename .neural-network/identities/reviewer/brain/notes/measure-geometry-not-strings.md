---
tags: [css, layout, review, headless]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "#397 retro"
learned-from: 3 MAJORs invisible to string asserts
graduated: false
created: 2026-07-24
---

For any neural-view.html change touching layout (height/min-height/max-height/flex/overflow/position or the vars --voiceh/--voice-below/--colq/--log-space), a green template-test run is necessary but NOT sufficient: those tests assert CSS substrings, never rendered boxes. Build a faithful minimal headless repro (exact rules + real DOM + the actual JS measurement reads like applyUiState's offsetHeight) and measure offsetHeight/scrollHeight/getBoundingClientRect at a short (~700px) viewport and a tall one (emulate by overriding --colq), across every interactive state the change can touch (base, folded, collapsed). The bugs live in the gap between the CSS string and the rendered pixel — especially where a percentage/min/max resolves against a var, or JS reads offsetHeight (which never reflects overflow:visible spill). Prove a regression is NEW by re-injecting the old rule and measuring the delta.
