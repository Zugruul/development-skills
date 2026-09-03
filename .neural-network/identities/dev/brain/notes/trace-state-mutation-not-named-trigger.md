---
tags: [debugging, frontend, input]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "PR#83 (#71) retro"
graduated: false
created: 2026-07-08
---

When a bug report says "action X causes Y", don't trust the named trigger — trace the state mutation backwards from Y: enumerate every call site that sets the state, check each one's guard conditions. The #71 culprit was pointermove jitter, not the reported pointerdown; the fix (a 4px moved flag) already existed unconnected, two lines away.

Related: [[raf-rearm-first]] [[anonymous-listener-slice-eval]]
