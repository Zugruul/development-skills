---
tags: [testing, harness, dom]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "retro AST-023 (round-2 crasher)"
graduated: false
created: 2026-07-24
---

A test double must reproduce the FAILURE SEMANTICS of the real interface, not just its happy-path API: getter-only properties (HTMLCollection.length), strict-mode assignment throws, live-collection behavior. A plain-array `children` stub let `.children.length = 0` ship green through two tasks while crashing every real browser open. When a stub-masked defect is found, fix BOTH places — the code site and the stub — so the entire class is guarded from then on.

Related: [[anonymous-listener-slice-eval]] [[inspect-red-before-trusting]]
