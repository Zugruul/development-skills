---
tags: [shell, quoting, bash]
paths: ["plugins/spec-workflow/scripts/*.sh"]
strength: 1
source: "PR#237 dev retro, self-caught bug"
graduated: false
created: 2026-07-21
---

A comment inserted inside a python3 -c '...' single-quoted heredoc-style block must never contain an unbalanced literal apostrophe -- it silently breaks the whole shell quoting (unexpected EOF / syntax error), catchable immediately via bash -n before running the gate. Verify quoting mechanically (bash -n) rather than eyeballing that a comment looks fine, especially when copying an existing file's python3-heredoc style.

Related: [[prefer-structural-signal-over-keyword-gate]]
