# Design — sw/E1: Hardening
Grounded in: SPEC §7 (§7.1–§7.6), §2 G2

## Components
`tree-state.sh` — the gate-pass fingerprint: hashes the working tree state; `gate.sh` records it, `guard-board-move.sh` compares it. SW-010 extends it to untracked-file content.
`guard-board-move.sh` — PreToolUse hook guarding *In review* moves. SW-011 replaces substring grep with subcommand+target parsing.
`next.py` — picker messaging (SW-012). `board.sh` — pagination (SW-013). `run-tests.sh` — flake handling (SW-014). `brain.py` — tag escaping (SW-015).

## Data models
Gate-pass file (`.claude/gate-pass`): a single fingerprint line binding a recorded green gate to an exact tree state. Fingerprint = hash over: HEAD commit + tracked diff hash + (NEW, SW-010) per-file content hashes of `git ls-files --others --exclude-standard` output. Any change to tracked OR untracked content invalidates the pass.

## Interfaces / contracts
`tree-state.sh` prints one deterministic fingerprint line for the repo at cwd; identical trees ⇒ identical output; any content change (tracked edit, untracked add/modify/delete) ⇒ different output. No network, no clock.
`guard-board-move.sh` receives the hook's JSON on stdin; it must PARSE the board.sh invocation: block iff the parsed SUBCOMMAND is `move` AND the parsed TARGET STATUS equals the review-gate status — never because a status name appears anywhere else in the command string (issue bodies, comment text, file paths). Non-move subcommands (comment, edit-body, bug, show, list…) always pass. Live false-positive evidence on issue #13: a `move N Backlog` blocked because the embedded issue BODY contained a status phrase; a comment blocked for the same reason.

## Key sequences
1. gate.sh green → writes fingerprint via tree-state.sh. 2. Any tool call matching the guard's trigger → hook recomputes fingerprint, compares to recorded; mismatch → block with remediation message. 3. SW-010 closes the hole where editing an UNTRACKED file after a green gate leaves the fingerprint unchanged (untracked content currently invisible to it).

## Decisions
Untracked hashing uses `git hash-object` (or shasum) per file over `git ls-files --others --exclude-standard` — respects .gitignore (ignored files stay outside the fingerprint: local state like .claude/feedback must not invalidate passes). WHY: the gate protects merged code; ignored local state churn would make passes unusably volatile.
Guard parses with a small tokenizer (bash/python) on the command string extracted from hook JSON — finds the board.sh argv, identifies argv[1] (subcommand) and the status argument — rather than regex-matching the whole string. WHY: the whole-string grep provably false-positives on embedded text (issue #13 evidence).
Empty-untracked-set behavior: fingerprint must remain stable/equal to the tracked-only fingerprint shape (no spurious invalidation when nothing is untracked).

## Out of scope for this epic
Workflow UX (E0) and self-improvement machinery (E2). Neural-view work (#28/#30). Telemetry (SW-023/024 are E2 §8.4 despite the SW-02x numbering — follow the board's epic mapping).
