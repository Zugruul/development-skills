---
tags: [debugging, hotfix]
paths: ["**"]
strength: 1
source: "#90 retro"
graduated: false
created: 2026-07-08
---

For a hotfix to a just-shipped feature, the fastest signal is reproducing the incident report's EXACT command sequence (adopt, then move) — not the spec's happy path. The two #90 failures lived in different functions and neither was visible from the other's fix; only the incident sequence exposed both.

Related: [[stderr-suppression-hides-evidence]] [[unassumed-full-pipeline-repro]]
