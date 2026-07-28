---
tags: [process, acceptance-criteria, audit]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #340"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

For a multi-clause acceptance criterion, audit each clause against what is ALREADY landed as an explicit first step — before writing any code. Two of three clauses were fully covered by decisions from two tasks earlier; the audit narrowed the real work to one new regression test plus the genuinely open halves, instead of reimplementing landed filtering.

Related: [[validate-the-declaration-not-just-values]]
