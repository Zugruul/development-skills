---
tags: [review, tdd, verification]
paths: ["**"]
strength: 1
source: "retro 2026-07-21 GL epic E0 reviews"
graduated: false
created: 2026-07-21
---

Verify red-first claims by RUNNING the new tests against the base/pre-fix tree, never by reading them. Twice in one session this exposed defects reading missed: an assertion red for the wrong reason (fixture arithmetic), and an identity check that stayed green while the file demonstrably lost entries (vacuous multiline grep). The delta in failure counts between base and HEAD is the proof of what the tests actually pin.

Related: [[reproduce-then-verify-fix]]
