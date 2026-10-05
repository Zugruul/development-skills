---
tags: [review, integrity, vendor]
paths: ["plugins/spec-workflow/templates/vendor/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#61 (#60) retro"
graduated: false
created: 2026-07-07
---

Hash/checksum values in a diff are exactly where copy-paste errors are invisible to visual diffing — recompute them yourself (shasum -a 256) against the actual file instead of comparing quoted strings by eye. Same principle for "red" claims: check out the red commit and observe the failure state directly rather than trusting the commit-message tag.

Related: [[verify-guard-regex-on-real-artifact]]
