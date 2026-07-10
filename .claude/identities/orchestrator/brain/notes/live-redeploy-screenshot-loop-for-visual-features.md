---
tags: [workflow, testing, ui, visual]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "feedback item 2, 2026-07-10T06:30:00Z"
graduated: false
created: 2026-07-10
---

For a highly visual/interactive feature (a live physics sim, a 3D layout, UI
spacing), redeploying each fix to a real running instance and having the
human screenshot the result in near-real-time catches things automated
tests structurally can't: layout overflow, simulation instability, node
oscillation. Prefer this loop over guessing-then-asking when the change is
hard to reason about from source alone.
