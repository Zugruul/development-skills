---
tags: [review, testing, python]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#81 review retro"
graduated: false
created: 2026-07-08
---

When a code path is real but its trigger is rare/adversarial to construct honestly (rules designed never to produce invalid output), monkeypatch exactly ONE function (e.g. validate()) to drive execution into the branch while keeping every other effect real — then assert on real state (file md5s, re-detectability), not inference from reading.

Related: [[outcome-language-marks-unverified-seams]]
