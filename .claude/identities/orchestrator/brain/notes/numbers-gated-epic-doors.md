---
tags: [gates, measurement, epics, process]
paths: ["**"]
strength: 1
source: "session close AST E0+E1"
graduated: false
created: 2026-07-22
---

Gate epics whose value depends on latency/feel (UI, voice) behind committed real-mode measurement artifacts: ship the harness with a CI stub mode proving the instrument and a manual real mode producing the numbers; commit the results JSON; let the recorded threshold verdict open the door. Worked end-to-end for the E1→E2 gate (real p95 5.67s vs 15s, results in docs/gates/) — the artifact doubles as the audit trail for WHY the epic opened, and a provider-dependent simulation gap surfaced honestly instead of being averaged away.

Related: [[brief-closed-action-set]] [[combined-two-pass-for-small-siblings]]
