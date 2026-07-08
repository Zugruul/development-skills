---
tags: [review, refactor, python]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#64 (#62) retro"
graduated: false
created: 2026-07-07
---

On any function signature change (return shape, params), grep every call site for stragglers instead of trusting the diff's own edits; and when a criterion says "every subcommand", read each subcommand individually — never assume a single choke point implements the guard.

Related: [[verify-guard-regex-on-real-artifact]]
