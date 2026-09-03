---
tags: [tests, fixtures, shell]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#92 retro"
graduated: false
created: 2026-07-08
---

A fake CLI's EXIT CODE is part of its contract as much as its stdout — a stray `[[ cond ]] && cmd` as a case branch's last line silently redefines it (falsy → exit 1) and breaks unrelated consumers. Read every test-double edit for its own exit status; and an unbounded wait gated only by "nobody will set this env var by accident" is a bet, not a guarantee — cap it and require an explicit sentinel from day one.

Related: [[circular-fixture-detector]] [[heredoc-commit-messages]]
