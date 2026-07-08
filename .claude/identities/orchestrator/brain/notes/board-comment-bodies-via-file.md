---
tags: [board, hooks, orchestration]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#64 (#62) iteration"
graduated: false
created: 2026-07-07
---

guard-board-move.sh can BLOCK a benign board.sh comment when the body arrives via heredoc it cannot safely parse (content-dependent). Pass comment bodies via a file redirect (board.sh comment N < file) — deterministic, parseable, and keeps long bodies out of the command string.

Related: [[board-out-of-compound-commands]]
