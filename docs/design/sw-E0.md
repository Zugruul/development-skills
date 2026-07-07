# Design — sw/E0: Workflow UX
Grounded in: SPEC §6 (§6.1–§6.5), §2 G1

## Components
`similar.py` — stdlib-python scoring engine: title+body similarity over a board issue list, ranked matches + confidence tiers (high/medium/low). No board access of its own — reads issues from `board.sh list`/`show` output the caller passes in. (SW-001)
`/find-task` skill — thin wrapper: takes a query, shells out to `similar.py` via `board.sh`, prints ranked matches with number/status/score, no writes. (SW-002)
`/create-inbound` skill — capture flow: runs the §6.1 search first, branches on confidence tier (high → comment-not-create default; medium → ask per OQ-4; low → create), marks inbound, sets priority, adds to board. (SW-003)

## Data models
`IssueRecord`: `{number: int, title: str, body: str, status: str}` — the unit `similar.py` scores against.
`Match`: `{number: int, title: str, status: str, score: float, tier: "high"|"medium"|"low"}` — one ranked result.
Tiers are score-band cutoffs documented in `similar.py`'s header (not spec-governed — an implementation detail that can be re-tuned without a spec delta, as long as high/medium/low ordering holds).

## Interfaces / contracts
`similar.py <root> "<query>"` — reads board issues (open+closed) via the same config the caller resolves (`root` = repo root passed to `config.py`/`board.sh`, matching every other script in `scripts/`), prints ranked matches one per line: `<tier>\t<score>\t#<number>\t<status>\t<title>`. Exit 0 always (no results is a valid empty answer, not an error) — matches `board.sh next`'s convention of print-then-decide rather than fail closed on "nothing found".
`/find-task` and `/create-inbound` (SW-002/SW-003, not this task) consume `similar.py`'s stdout; they own the board write path, `similar.py` never writes.

## Key sequences
1. Caller obtains the issue corpus (open+closed) — this task's tests supply it via fixtures shaped like `board.sh list`'s output; the real `/find-task`/`/create-inbound` skills (SW-002/003) will pipe live `board.sh` data through the same shape.
2. `similar.py` normalizes+scores query against each issue's title and body, picks the max of the two, ranks descending, assigns a tier by the documented thresholds.
3. Output is deterministic for identical input (no network, no clock) — the hermetic test suite fixtures exact-title, paraphrase, and no-match cases per the SW-001 acceptance criteria.

## Decisions
Score algorithm: token-overlap / normalized-edit-distance over stdlib only (`difflib.SequenceMatcher`, no numpy/sklearn) — WHY: `specs[].invariants` mandates stdlib-only Python with PyYAML as the sole dependency; a similarity script is exactly the kind of thing that tempts a vector/embedding dependency, which §3 non-goals explicitly rules out for v1.
Board access: `similar.py` takes issue data as an argument/fixture, it does not call `gh`/`board.sh` itself — WHY: `specs[].invariants` states `board.sh` is the only board access; keeping `similar.py` a pure scoring function keeps it hermetically testable and keeps the live-data boundary in one place (the SW-002 skill), per SPEC §6's "own tests, never prose instructions" constraint.

## Out of scope for this epic
`/find-task` and `/create-inbound` skills themselves (SW-002, SW-003) — this task only ships the scoring script they will wrap.
OQ-1..OQ-4 answers (inbound marking scheme, override UX) — SW-003's concern.
