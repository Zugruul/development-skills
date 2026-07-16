---
tags: [bash, testing, exit-code]
paths: []
strength: 1
source: "task #130 (MEM-011)"
graduated: false
created: 2026-07-16
---

A test that checks WHAT a command prints but never WHETHER it succeeded is blind to a whole failure mode -- pin bash helper contracts on both axes (output AND exit code), not just output.

Why: MEM-010's spec_workflow_local_state_paths used the common `while read ... || [[ -n \"$x\" ]]` idiom for catching a final unterminated line, which leaves $?==1 at EOF -- so the function returned FAILURE on success. MEM-010's own tests only diffed stdout and never asserted $?, so it shipped invisibly and only surfaced when MEM-011's gitignore-sync.sh became the first strict (`|| exit 1`-guarded) caller.

How to apply: when testing a bash library function, assert its exit code explicitly, not just its output -- especially for any function ending on a `while read` loop over process substitution/pipe/heredoc, which can leave a stale nonzero $? at EOF even on a fully successful read. Corollary: becoming a merged helper's first strict caller is itself a test -- expect it to surface rc/exit-option bugs the original task's own tests couldn't see.
