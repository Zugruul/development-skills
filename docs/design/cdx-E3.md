# Design — cdx/E3: Build-loop & enforcement parity
Grounded in: SPEC-CODEX-COMPAT.md §9.1–§9.3, §12, §14

## Components
`plugins/spec-workflow/scripts/gate-preflight.sh` (new) — hook-independent, callable preflight
that answers one question: "is there a recorded gate pass for the current tree fingerprint?".
Exposes the same marker-exists + fingerprint-match logic currently embedded in
`guard-board-move.sh`, as a standalone script any workflow (Claude hook, Codex explicit step, or
a human running `board.sh` by hand) can invoke identically. (CDX-030)
`plugins/spec-workflow/scripts/guard-board-move.sh` (unchanged behavior) — Claude `PreToolUse`
hook; continues to intercept `board.sh move <n> "In review"` Bash calls and block on a missing/
stale gate pass. Kept as defense in depth per §9.3 — not replaced, not weakened.
`plugins/spec-workflow/scripts/board-queue.sh`'s `_do_move()` — gains an explicit call to the new
preflight before mutating status to "In review", so the check fires even when no hook is present
to intercept the call (Codex, or `board.sh` invoked directly under Claude e.g. via a non-Bash-tool
path). This is the actual gap closed by CDX-030: today `_do_move()` has zero gate-awareness.

## Data models
No new persistent state. Reuses the existing `.claude/gate-pass` marker (plain-text SHA-256
fingerprint, written by `gate.sh`) and `tree-state.sh`'s fingerprint computation — both already
exclude `.claude/gate-pass`/`telemetry.jsonl`/`lessons.jsonl`/`board-cache.json` from the hash so
routine state-file writes never self-invalidate a pass.

## Interfaces / contracts
`gate-preflight.sh` — no stdin required (unlike the hook, which parses hook JSON). Invocation:
`bash gate-preflight.sh` (optionally `--root <path>` for tests, default: `git rev-parse
--show-toplevel`). Exit 0 + silent stdout when a valid pass exists for the current fingerprint.
Exit non-zero + actionable stderr message (same wording style as the hook's existing block
message) when the marker is missing or stale. No side effects — read-only.
Both `guard-board-move.sh` and `board-queue.sh`'s `_do_move()` call this same script/function
rather than each re-implementing the marker+fingerprint check — single source of truth for "is
the gate green for this tree."
`_do_move()` contract change: when the normalized target status is "in review", it now runs the
preflight before calling `_mutate_field`; a failing preflight aborts the move with the same class
of error `board.sh` already uses for other precondition failures (non-zero return, message on
stderr), and does NOT touch the board (no partial mutation, no queued op).

## Key sequences
1. **Claude, hook present (existing path, unchanged):** dev/orchestrator runs `board.sh move N
   "In review"` as a Bash tool call → `PreToolUse` hook fires → `guard-board-move.sh` parses the
   command, detects a review-move, calls the shared preflight check, blocks or allows *before*
   `board.sh` even starts. If allowed, `board.sh move` runs and its own internal preflight (step
   2 below) trivially passes too (defense in depth, redundant but harmless).
2. **Codex, or any hook-independent path (new):** `board.sh move N "In review"` runs with no
   interception. `_do_move()` detects target status "In review", calls the same preflight script.
   Missing/stale pass → move blocked, same actionable message, non-zero exit, nothing queued or
   mutated. Valid pass → move proceeds exactly as before.
3. **Red-first regression test:** a new test section invokes `board.sh move <n> "In review"`
   directly — no hook JSON piped in anywhere, hook script never invoked — against a fixture repo
   with no `.claude/gate-pass` present, and asserts the move is still blocked. This test is
   red against pre-CDX-030 `board.sh` (which has no internal gate-awareness) and green once
   `_do_move()`'s new preflight call lands.

## Decisions
Extract into a standalone script (not a bash function embedded only in `guard-board-move.sh`) —
WHY: `board-queue.sh` and `guard-board-move.sh` are separate scripts/processes (the hook runs in
its own bash invocation from Claude's hook runner); a shared script is the simplest way to keep
one implementation of the marker+fingerprint logic without introducing a new `lib/*.sh` sourcing
dependency between them for a two-branch check.
Keep `guard-board-move.sh`'s own inline check rather than deleting it in favor of only calling the
new script — WHY: §9.3 requires the hook to keep "functioning as defense in depth," and the
hook's existing tests (`section-gate-core.sh`) already exercise it directly; having the hook also
call the shared script (rather than duplicate the logic) satisfies both "unchanged behavior" and
"single source of truth" without a second maintained copy of the check.
Enforcement point is `_do_move()`, not `board.sh`'s `move)` case — WHY: `_do_move()` is the single
function that performs the actual `_mutate_field` call regardless of entrypoint (direct call,
future non-hook wrapper, etc.); putting the check any higher risks a future caller of `_do_move()`
bypassing it.

## Out of scope for this task
CDX-031 (Codex-path parity walkthrough for the rest of the build-loop invariants — §9.2) and
CDX-032 (`session-start.sh` bootstrap equivalent) — sibling E3 tasks, not this task's deliverable.
Any change to `hooks/hooks.json` wiring or to `gate.sh`'s pass-recording behavior — both stay
exactly as they are; CDX-030 only adds a new, independent call site for the existing check.
