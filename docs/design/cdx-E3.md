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

## CDX-031 — `build-next`/`implement-task` Codex-path parity walkthrough (§9.2)

**§9.2 exact text**: "THE SYSTEM SHALL preserve, under both hosts, without weakening: truthful board-status transitions, human-issue-comment steering read before implementation, red-first TDD, independent two-pass review, identity-brain isolation (orchestrator-mediated only), mandatory retro/feedback at PR close, checkpoint behavior (no new task starts while paused), isolated concurrency lanes respecting `methodology.maxInProgress`, and bounded auto-merge review rounds."

**Method**: for each of the 9 invariants, determine whether it is SCRIPT-ENFORCED (deterministic, works identically under any host that can invoke an explicit step — Codex included), HOOK-ONLY (depends on a Claude-specific `SessionStart`/`PreToolUse` hook that silently would not fire under Codex), or PROSE-ONLY (relies entirely on the acting agent following SKILL.md instructions, with nothing technical that would catch or block a violation). Every claim below is grounded in the actual current code, not assumed — file:function citations throughout.

### Per-invariant audit

**1. Truthful board-status transitions — SCRIPT-ENFORCED (host-neutral).** This is exactly CDX-030 above: `gate-preflight.sh` is invoked from `board-queue.sh`'s `_do_move()` unconditionally, regardless of caller/hook presence. `guard-board-move.sh` (the Claude hook) calls the identical script as defense-in-depth. Broader board-status truthfulness is separately checked post-hoc by `board.sh audit`/`audit.py` — deterministic but reactive, not move-time-blocking. **Test coverage**: `tests/section-gate-preflight.sh` calls `board.sh move` directly with no hook JSON piped in and asserts the move is still blocked — genuine "hooks absent" simulation, and the **only** one of the 9 invariants with that pattern applied.

**2. Human-issue-comment steering read before implementation — PROSE-ONLY.** `skills/next-task/SKILL.md` and `skills/implement-task/SKILL.md` §0.1 both instruct "`board.sh show N` — read the body and every comment," but nothing records that this happened or gates any subsequent action (branch creation, `board.sh move N "In progress"`) on it. No test coverage found beyond `show`'s own comment-formatting/labeling tests.

**3. Red-first TDD — PROSE-ONLY.** `implement-task/SKILL.md` briefs the dev subagent to commit failing tests first; verification is a manual instruction to the orchestrator ("check `git log`," `build-next/SKILL.md` Operating Rule 4). `scripts/gate.sh` has no git-log/commit-order inspection of any kind — it only runs `commands.gate` and records a tree-fingerprinted pass/fail. No script anywhere checks commit ordering. No test coverage found.

**4. Independent two-pass review — PROSE-ONLY.** `implement-task/SKILL.md` §3 describes two review passes (spec compliance, then code quality) as orchestrator protocol; nothing verifies two passes occurred or that they were genuinely independent (distinct agent invocations). `telemetry.py` records `review-round` events (a log) but nothing reads them back to require ≥2 before merge/close. No test coverage beyond schema validation of the telemetry record shape.

**5. Identity-brain isolation (orchestrator-mediated only) — PROSE-ONLY.** `build-next/references/brains.md` states "only the orchestrator process ever reads or writes a brain… subagents never see a brain path" as design intent — no ACL, no `allowed-tools` restriction, no file permission mechanism found. The only actual mitigation is that briefs never include the brain path — an omission-based convention defeated the moment a subagent independently discovers it (e.g. `find .claude`). No test coverage.

**6. Mandatory retro/feedback at PR close — PROSE-ONLY.** `implement-task/SKILL.md` §4 / `build-next/SKILL.md` step 7 declare retro "MANDATORY at PR close" with a stated-reason escape hatch and a `telemetry.py record '{"kind":"retro-skip",...}'` call. `telemetry.py`'s `retro-skip` kind only validates that `reason` is present — it is a **log**, not a gate; nothing reads it back to block a merge, board move, or loop-iteration close if retro (or even the skip record) is simply never invoked. `tests/section-telemetry.sh` has **zero** coverage for `retro-skip` (not even a schema test).

**7. Checkpoint behavior (no new task starts while paused) — PROSE-ONLY, with a HOOK-ONLY advisory layer.** `scripts/session-start.sh` (the `SessionStart` hook) prints an advisory message when `.claude/CHECKPOINT` exists — Claude-only, silently absent under Codex. But critically: **no script anywhere** — not `board.sh`, `board-queue.sh`'s `_do_move`, `next.py`, `preflight.sh`, or `gate-preflight.sh` — ever checks for `.claude/CHECKPOINT`'s existence before a mutation. `board.sh move N "In progress"` succeeds unconditionally regardless of the flag. `tests/section-session-init.sh` only asserts the advisory **message text** appears, never that any mutation is actually blocked (because none is). This is the genuinely riskiest gap of the 9: the flag's only effect anywhere in the codebase is a Claude-only reminder message.

**8. Isolated concurrency lanes respecting `methodology.maxInProgress` — PROSE-ONLY at the actual mutation point.** `scripts/next.py` correctly computes WIP count vs. `maxInProgress` and prints `RESUME` instead of `PICK` when at the limit (deterministic, script-computed) — but this is **advisory output only**; nothing prevents `board.sh move <other-N> "In progress"` from being called directly regardless of what `next.py` printed. `maxInProgress` does not appear anywhere in `board.sh`/`board-queue.sh`'s move logic. Note: `build-next/SKILL.md` Operating Rule 8 currently claims "`next.py` enforces the WIP limit board-side" — this is **inaccurate** as written; `next.py` only informs the pick decision. `tests/section-concurrency.sh` only tests config get/set round-tripping, never WIP-limit-blocking behavior.

**9. Bounded auto-merge review rounds — PROSE-ONLY.** `build-next/references/auto-review.md` §2 documents "max 3 rounds" as orchestrator protocol. `telemetry.py` records `review-round` events but never caps or reads back the count to refuse a 4th round. No script in `board.sh`/`guard-pr-create.sh`/`merge-mode.sh` enforces a limit. No test coverage.

### Summary table

| # | Invariant | Verdict | Enforcement point |
|---|---|---|---|
| 1 | Truthful board-status transitions | **SCRIPT-ENFORCED** | `gate-preflight.sh` via `board-queue.sh:_do_move()` (+ hook, defense-in-depth) |
| 2 | Human-comment steering read | PROSE-ONLY | SKILL.md instruction only |
| 3 | Red-first TDD | PROSE-ONLY | Manual `git log` check instruction |
| 4 | Independent two-pass review | PROSE-ONLY | SKILL.md protocol; telemetry logs, doesn't gate |
| 5 | Identity-brain isolation | PROSE-ONLY | Convention (path omitted from briefs); no ACL |
| 6 | Mandatory retro/feedback | PROSE-ONLY | `retro-skip` telemetry is a log, not a preventer |
| 7 | Checkpoint (no new task while paused) | PROSE-ONLY (+ Claude-only advisory hook) | No script checks the flag before a mutation, ever |
| 8 | WIP limit (`maxInProgress`) lanes | PROSE-ONLY at mutation point | `next.py` advises correctly; `board.sh` move has no WIP awareness |
| 9 | Bounded auto-merge review rounds | PROSE-ONLY | `auto-review.md` convention; telemetry doesn't cap |

**8 of 9 invariants are currently prose-only — under BOTH hosts, not just Codex.** Codex doesn't make any of these worse than they already are under Claude (none of the 8 currently depend on a Claude-only mechanism Codex lacks); the one Claude-only piece that exists (`session-start.sh`'s checkpoint advisory) was never load-bearing to begin with, since nothing downstream of it actually blocks on the flag either. The single invariant that IS genuinely host-neutral and script-enforced (#1) only became so via CDX-030 — exactly the kind of fix the other 8 need.

### Scope decision for THIS task (CDX-031)

Per the acceptance criterion and DoD ("any invariant that can't be verified as script-enforced is called out explicitly, not assumed" / "any gap found becomes its own follow-up task rather than being silently accepted"): this task's job is the WALKTHROUGH — audit, document, and hand off — not to implement fixes for all 8 gaps in one 5-point task. Concretely:

1. This design doc section IS the audit deliverable — every invariant has an explicit, cited verdict.
2. A new test (`section-codex-parity-walkthrough.sh`) pins the design doc's completeness: asserts all 9 invariants are present in this doc with a verdict + citation, and that invariant #1's existing test coverage (`section-gate-preflight.sh`) is named — a structural/regression guard so this document can't silently rot out of sync with the codebase, not a re-verification of the verdicts themselves.
3. Each of the 8 gaps becomes its own follow-up backlog item (`board.sh bug`), filed at this task's close, each citing this design doc's relevant section. Priority: P1 (this epic's baseline) — no new elevation is asserted here without the same kind of explicit justification CDX-030 gave for itself.
4. Invariant #8's inaccurate claim in `build-next/SKILL.md` Operating Rule 8 is flagged in that follow-up's issue body as something the fix should also correct — not fixed in this task, since the wording should be updated in the SAME PR that changes the behavior it describes.

**Constraints preserved**: no attempt is made to "fix" any of the 8 gaps here. The suite stays green; the design doc section + new pinning test + filed follow-ups are the complete, honest deliverable for a 5-point audit task.
