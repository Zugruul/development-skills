---
tags: [tests, docs, skills]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "#406 retro"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Before rewriting tested prose (SKILL.md sweeps), grep the suite for pinned substrings AND verify the match MECHANISM: check() is grep -qF substring, so a pinned heading only needs to survive as a substring/prefix, not verbatim. One research pass enumerating actual pins across the test tree turned a feared 31-file minefield into one real constraint.

Related: [[copy-exact-strings-tests-assert-against]]
