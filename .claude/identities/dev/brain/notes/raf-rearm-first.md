---
tags: [frontend, resilience, render-loop]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "PR#69 (#68) retro"
graduated: false
created: 2026-07-07
---

In a requestAnimationFrame loop, the re-arm call must be the FIRST statement of the frame body — a tail re-arm means any per-frame exception permanently kills the loop (black screen). When fixing a specific per-frame crash, treat "loop dies on one exception" as a second, independent bug of its own class and fix both.

Related: [[red-static-vs-wiring-checks]]
