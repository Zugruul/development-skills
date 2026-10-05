---
tags: [review]
paths: []
strength: 1
source: "retro 2026-07-11, feedback item"
graduated: false
created: 2026-07-11
---

An independent, skeptical review pass is worth the overhead even when the implementing agent reports its own tests green -- especially when the reviewer is explicitly told to check whether a fix reintroduces the SAME bug class it's supposed to close. Self-testing by the author of a fix is prone to missing the exact failure window the fix targets; a fresh pair of eyes looking specifically for that recurrence caught a real, non-obvious atomicity bug this session that the implementer's own passing tests had missed.
