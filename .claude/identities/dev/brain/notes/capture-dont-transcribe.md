---
tags: [fixtures, provenance, testing]
paths: ["**"]
strength: 2
source: "#50 retro — recurrence (behavioral vs classifier tests)"
graduated: false
created: 2026-07-08
---

Corollary: know WHICH KIND of test you are writing — a CLASSIFIER test (asserts code recognizes real gh/tool wording) needs corpus-sourced real captures; a BEHAVIORAL test (asserts your code's own reaction to a trigger: nonzero exit, malformed byte) is legitimately served by synthetic stub markers ("fake gh: ... boom") and needs no corpus.
