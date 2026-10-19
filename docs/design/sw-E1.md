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

## Follow-up: #285 — preserve pre-existing checkout changes

Grounded in SPEC §4 (isolated lanes), §7 (hardening), §9 (script decisions, TDD), SPEC-CODEX-COMPAT §9.2 (no-hook enforcement and unrelated work preservation), and the issue's explicit dirty-clone isolation request. #532 introduced checkout preference but build-next still says to switch/pull before inspecting local changes.

### Components and interface
A shared read-only checkout inspection command (`scripts/checkout-preflight.sh`, with a stdlib Python helper if useful) examines the ACTUAL checkout selected by cwd (or an explicit root), not the primary checkout returned by shared telemetry resolution. It reports a deterministic clean/dirty/uninspectable decision and the checkout path. Direct callers receive a nonzero result for dirty or unknown state; the existing advisory preflight retains its always-zero load-time contract and surfaces the decision without pretending a dirty checkout is clean.

Use Git's stable machine-readable status, including staged, unstaged, deleted, renamed, unmerged and untracked paths, independent of status.showUntrackedFiles and submodule ignore preferences. Ignored runtime state stays ignored. No index refresh writes (disable optional locks), no network, no temp files in the consumer, no stash/checkout/reset/add/commit. Report filenames safely without reading file contents; do not interpret unusual filenames as shell syntax. Inspection failures are unknown, never clean. Do not claim to distinguish the human's edits from another agent's edits: all pre-existing changes are treated as unowned.

### Startup sequence
1. Before any switch/pull or implementation, build-next inspects the selected checkout. Clean follows the existing checkout preference and workflow.
2. Dirty: preserve HEAD, index and all worktree bytes. With existing authorization for worktree isolation, fetch without switching the dirty checkout and create a separate clean orchestration/task worktree from the configured remote main (or local main if no remote exists); follow existing register-first workflow there. Do not quietly switch an explicitly chosen main-only session to worktree mode: if isolation is not authorized, pause with the exact dirty paths and the needed choice.
3. Uninspectable: stop checkout mutation and report the inspection error. Re-run inspection in the isolated checkout before its switch/pull. A dirty primary must not block a separately verified clean linked task checkout.

Update build-next startup ordering and implement-task registration references; reuse the helper from advisory preflight. Explicitly document the limitation: a check is a point-in-time observation, not an OS lock against another writer appearing afterward. Existing per-task complete commits/lane isolation and gate checks still apply; no false cross-process enforcement claim.

### Validation and scope
Real disposable Git repositories test clean/dirty variants, hidden untracked/submodule dirtiness, unusual names, linked worktree vs primary, Git inspection errors and before/after identity of HEAD/index/worktree/stash. Exercise the actual startup/advisory entrypoints, with instruction-order coverage for check-before-switch/pull. Preserve #274's existing config/ignore freshness behavior and advisory exit contract. Tests fail and commit before production edits; full configured gate remains mandatory.

No automatic cleanup/stashing, no session ownership registry, no changes to WIP/session-scoping or remote sync, no schema change. Update root/plugin README and a pending SPEC delta for the new hardening contract; canonical SPEC changes only after merge.
