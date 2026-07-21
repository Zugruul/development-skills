---
tags: [python, jsonl, validation, robustness]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "retro 2026-07-21 GL-003 review round"
graduated: false
created: 2026-07-21
---

Presence-validation of JSONL fields is not enough: a JSON-valid line with wrong TYPES (int where iso-ts string expected, list where str slug expected) passes presence checks then crashes downstream comparisons (`ts < cutoff` TypeError) or hashing (unhashable dict key). isinstance-validate in the single shared reader and route wrong-type lines through the same malformed path (warn once, disable feature, exit 0).

Related: [[strict-identity-assertions]]
