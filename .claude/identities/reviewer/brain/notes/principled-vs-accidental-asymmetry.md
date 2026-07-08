---
tags: [review, semantics, api]
paths: ["**"]
strength: 1
source: "#96 review (empty env vs explicit-empty flag)"
graduated: false
created: 2026-07-08
---

When two related inputs are handled differently, classify before flagging: PRINCIPLED if you can state the predictive rule a user would give WITHOUT referencing code internals ("unset env is the ambient off-state; typing the flag is deliberate, so deliberately-empty is a mistake") -> note it, don't flag — but require one line of doc, because an undocumented defensible asymmetry decays into an accidental-looking one that the next reader "fixes" into a footgun. ACCIDENTAL if the only justification describes code paths -> flag it.
