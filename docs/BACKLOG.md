# Backlog — spec SW (SPEC.md)

Task ids: `SW-<number>`. Ranges: E0 = 001–009, E1 = 010–019, E2 = 020–029. Points ≈ complexity (1–10 rubric, seed-board skill). Every task cites its SPEC.md §s; acceptance criteria are the merge bar.

## E0 — Workflow UX (§6)

### SW-001 · Dedup/similarity script — P0 · 3 pts · §6.1 §6.3 §6.5
Scripted similarity over board issues (title+body, open+closed) with ranked scores and confidence tiers (high/medium/low).
**Acceptance:** a `scripts/` entry (stdlib python or bash) callable as `similar.py <root> "<query>"`; returns ranked matches with issue number + score + tier; thresholds documented in the script header; hermetic tests with fixture issue lists cover exact-title, paraphrase, and no-match cases; `board.sh` is the only live data source.
**DoD:** suite green, shellcheck clean, docs untouched (internal script).

### SW-002 · /find-task skill — P1 · 3 pts · §6.1
Skill wrapping SW-001: query → ranked existing tasks, with status + link, no writes.
**Acceptance:** terse SKILL.md (house style, allowed-tools Bash); bare invocation asks for the query; output shows top N with numbers/status/score; README tables updated (both).
**DoD:** suite green; skill listed in plugin README.

### SW-003 · /create-inbound skill + board add verb — P1 · 5 pts · §6.2–§6.5 §12(OQ-1..4)
Capture flow: search first (SW-001), present duplicates, create only on no-high-confidence-match (or explicit override), mark inbound per OQ-1, set priority, add to board.
**Acceptance:** implements the user's OQ-1..OQ-4 picks (or their defaults if still unanswered, noted on the issue); high-confidence duplicate → comment-not-create default (§6.3); created issue is pickable by `next.py`; tests via the fake-gh harness for create, dedupe-block, and override paths; READMEs updated.
**DoD:** suite green; OQ picks recorded on the issue before implementation starts.

*(SW-004–009 headroom for discovered E0 work.)*

## E1 — Hardening (§7)

### SW-010 · tree-state: hash untracked content — P0 · 3 pts · §7.1
**Acceptance:** fingerprint includes content hashes of `git ls-files --others --exclude-standard` files; red test proves the current hole (edit untracked file after green gate → move allowed) then the fix blocks it; gate-pass invalidation covered for add/modify/delete of untracked files.

### SW-011 · guard-board-move: parse, don't grep — P0 · 2 pts · §7.2
**Acceptance:** red test: `board.sh comment N "please move to in review"` is currently blocked (exit 2) → after fix, allowed; `board.sh move N "In review"` still blocked without a fresh pass; guard keys on parsed subcommand + target status.

### SW-012 · next.py: unseeded-epic message — P1 · 2 pts · §7.3
**Acceptance:** zero-item blocking epic stays fail-closed; message is exactly the `epic <id> unseeded — run seed-board` shape; existing satisfied/unsatisfied paths unchanged (regression tests).

### SW-013 · board.sh: pagination — P1 · 3 pts · §7.4
**Acceptance:** `next`/`list`/`move`/seeding paginate past the current `--limit` ceilings; fake-gh harness extended to serve 2+ pages; a >limit fixture proves items beyond page 1 are seen and addressable.

### SW-014 · flaky server-lifecycle tests — P2 · 3 pts · §7.5 (closes #8)
**Acceptance:** server-lifecycle sections use per-run randomized ports; a failing lifecycle check retries once and reports `FLAKY (passed on retry)` distinctly; issue #8 closed with the capture rationale.

### SW-015 · brain.py: quote+comma tag round-trip — P2 · 2 pts · §7.6
**Acceptance:** red test with tag `a"b,c` (the review-round-2 residual) → mint → render → re-parse → recall by that tag intact; escaping documented in the frontmatter parser header.

## E2 — Self-improvement completion (§8)

### SW-020 · gate.sh failure capture — P1 · 2 pts · §8.1
**Acceptance:** red gate appends `{ts, exit, tail}` JSONL to the lessons feed before clearing the pass; green gate appends nothing; feed path gitignored; retro reference updated to consume it.

### SW-021 · mandatory retro step — P1 · 2 pts · §8.2
**Acceptance:** build-next SKILL.md gains a numbered retro step at PR close; skipping requires a stated reason in the report; brains.md cross-referenced; no script change required (protocol text + report format).

### SW-022 · brain.py graduate-check — P1 · 3 pts · §8.3
**Acceptance:** `graduate-check <role>` lists notes at/above the strength threshold with a proposed destination; threshold configurable (default documented); tests cover below/at/above threshold and already-graduated exclusion.

### SW-023 · telemetry log + board.sh metrics — P0 · 5 pts · §8.4 §12(OQ-5)
**Acceptance:** loop appends per-iteration JSONL records (task, transitions+ts, gate attempts, review rounds, estimate) to `.claude/telemetry.jsonl` (gitignored); `board.sh metrics` prints cycle time per status, first-try gate rate, rework rate, estimate-vs-actual; deterministic tests on fixture logs; protocol references updated to write the records.

### SW-024 · estimate calibration report — P2 · 2 pts · §8.4
**Acceptance:** `board.sh metrics` includes per-point-bucket estimate accuracy once ≥5 closed tasks exist; degrades gracefully below that; fixture-driven test.

*(SW-025–029 headroom.)*
