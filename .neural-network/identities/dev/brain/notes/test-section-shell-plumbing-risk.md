---
tags: [tests, bash, quoting, heredoc, bash32]
paths: ["plugins/spec-workflow/tests/**"]
strength: 4
source: "session close (3rd confirmation, AST-018)"
graduated: false
created: 2026-07-22
---

In new-module tasks the real defect risk concentrates in the bash test-section plumbing. Bash-3.2 heredoc gotcha CONFIRMED A THIRD TIME (AST-018: apostrophe in a <<QUOTED heredoc body inside $() breaks the whole file parse even with a quoted delimiter; apostrophes outside $() spans are fine). bash -n before every section run is mandatory; no apostrophes in heredoc bodies under command substitution, ever.
