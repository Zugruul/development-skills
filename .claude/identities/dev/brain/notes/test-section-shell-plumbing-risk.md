---
tags: [tests, bash, quoting, heredoc, bash32]
paths: ["plugins/spec-workflow/tests/**"]
strength: 3
source: "PR-close #308 recurrence"
graduated: false
created: 2026-07-22
---

In new-module tasks the real defect risk concentrates in the bash test-section plumbing. Bash-3.2 heredoc gotcha RECURRED even with the lesson pasted in the brief (dev typed apostrophes into a <<PY body inside $() and caught it only via bash -n) — keep the lesson verbatim with the minimal repro, and treat bash -n as a mandatory pre-run step for any section edit.
