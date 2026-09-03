---
tags: [frontend, state, animation]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#73 retro"
graduated: false
created: 2026-07-08
---

Before calling a stateful feature done, enumerate every site that WRITES the state (not just where it's read) — the #73 flyAnim needed clearing at FOUR existing gesture call sites (orbit/pan/pinch/wheel), not just the frame step and reset. Camera/animation state is a small state machine that's easy to undercount.

Related: [[trace-state-mutation-not-named-trigger]] [[raf-rearm-first]]
