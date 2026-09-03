---
tags: [migration, yaml, archives]
paths: ["**"]
strength: 1
source: "#89 retro"
graduated: false
created: 2026-07-08
---

Before running a migration on a tracked archive: (1) grep the REAL file for every context the line-matcher will touch and check indentation empirically — PyYAML's default block-sequence style puts dash items at the SAME indent as their parent key, not deeper; (2) rehearse against a /tmp copy of the real target and diff — the only proof the live run produces exactly the expected diff, not a fixture-shaped approximation.

Related: [[surgical-yaml-edits]] [[single-cause-fixtures]]
