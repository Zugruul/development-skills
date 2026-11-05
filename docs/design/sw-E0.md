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
`similar.py <root> "<query>"` — `root` = repo root, the same convention every other script in `scripts/` takes (e.g. `config.py`'s), used only to derive the default fixture path (`<root>/.claude/tmp/similar-issues.json`); `similar.py` never calls `config.py` or `board.sh` itself. Prints ranked matches one per line: `<tier>\t<score>\t#<number>\t<status>\t<title>`. Exit 0 always (no results is a valid empty answer, not an error) — matches `board.sh next`'s convention of print-then-decide rather than fail closed on "nothing found".
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


## #277 extension — read-only project inventory
Grounded in SPEC §5 (current config engine/layout), §6 (workflow UX),
SPEC-GRAPHIFY multi-repo discovery, and issue #277's acceptance criteria.

### Components
- A shared Python discovery helper owns immediate-child anchored-directory scanning.
  `neural-view.py`, `sync-configs.py`, and the new inventory all call it.
- `projects-list.py` owns config inventory and a compact textual table plus `--json`.
- `neural-network-projects-list/SKILL.md` invokes the same engine on both hosts.

### Data models
Each row carries canonical repo path, project name, detected schema semver,
methodology values (`maxInProgress`, `autoMerge`, `serialDelivery`, feedback enabled,
`iterativeUI`), all board provider/number pairs, `OK`/`INVALID`, and first diagnostic.
Unspecified settings are explicit null/unspecified; do not infer configured values.
Boolean feedback shorthand is supported. Invalid rows preserve any safely readable
fields, without assuming nested values have mapping/list types.

### Interfaces / contracts
`python3 <resolved-plugin-root>/scripts/projects-list.py [--scan BASE] [--root DIR] [--json]`.
Scan defaults to `~/Development`; current root defaults to the invoking cwd's Git
root, falling back to cwd. `--root` explicitly selects the always-included repo.
Scanned siblings need a `.neural-network/` directory. Deduplicate canonical paths,
sort deterministically, and tolerate inaccessible bases/children. The explicit
current root is retained even when marker/config is absent, reporting INVALID.

Use the shared config loader's canonical filename ordering and legacy handling,
but ignore ambient `PROJECT_CONFIG` so one repo cannot impersonate every row.
Detect schema on raw parsed config with `config.schema_semver()` before legacy
normalization. Invoke the actual `validate-config.py` per repo in isolation; its
first error supplies the invalid diagnostic. Missing/unreadable files and validator
crashes are per-row INVALID diagnostics and never terminate the entire inventory.
No network, board calls, marker creation, config edits, cache files, or bytecode
writes. Invalid rows are successful inventory output; CLI usage errors remain errors.

### Key sequence
1. Pure shared discovery yields anchored immediate children; inventory adds current.
2. Load/validate each config independently, retaining partial readable information.
3. Print stable rows or structured JSON to stdout without saving inventory locally.

### Decisions
Preserve neural-view's existing explicit-root/fallback behavior (including its
existing fallback marker creation) and sync-configs' self-exclusion policy outside
the shared scan helper. The inventory never calls the mutating viewer fallback.
No third scanner, recursive scan, host-specific engine, or new schema field.
Skill registration uses existing Claude automatic discovery and Codex skills path;
no invented manifest keys. Update root/plugin skill indexes and add a scoped CDX
matrix entry without implying an audit of the whole marketplace.

### Out of scope
#278's selection/settings editing, live board status, recursive repository search,
changes to existing scanner caller policies, and schema migrations.

## #543 extension — herdr integration and task state
Grounded in SPEC §5 (config engine), §6 (workflow UX) and issue #543's acceptance criteria. Behaviour below was checked against herdr 0.9.5 and Claude Code hooks.

### Components
- `herdr-worktree.sh add|remove` owns task-lane creation and removal. Skills call it instead of `git worktree`.
- The `subagent-hook` mode of that script answers `SubagentStart` and `SubagentStop` from the plugin's `hooks.json`.
- `task-state.sh` owns the record of work in progress. `board.sh move` calls its `sync` verb.
- `herdr-plugin/` is a herdr plugin whose panel reads that record.

### Data models
- Config: `herdr: {enabled: bool, worktrees: {taskLanes: bool, subagents: bool}}`. Additive and absent by default, so no schema version bump.
- Task record: `{id, title, status, agents[], worktrees[], todos[{num, text, done, dropped?, active?, activeBy?}], updatedAt}`; a dropped TODO keeps its number and is not counted, stored at `<git common dir>/spec-workflow/task-state/<id>.json`.

### Decisions
- Top-level `herdr`, not `integrations.herdr` — WHY: `integrations` is defined as external task sources.
- Subagents use `SubagentStart`/`SubagentStop`, not `WorktreeCreate` — WHY: that hook replaces Claude Code's creation in every repo with the plugin, including `.worktreeinclude` handling. The chosen hooks are a no-op while off.
- Close the subagent workspace on stop — WHY: Claude Code removes clean agent worktrees, which would otherwise leave a "(deleted)" sidebar entry.
- Herdr only adds visibility, so any herdr failure falls back to git — WHY: display must never block delivery. A failed reply is checked against `git worktree list` first, because it does not prove nothing happened.
- Herdr's `--cwd` is the primary checkout, found from the git dirs rather than guessed (a submodule, separate git dir or bare repo has no `<parent>/.git`); when none is found git makes the lane — WHY: guessing put lanes in the wrong repository. It is always the primary checkout — WHY: herdr refuses worktree actions from a linked worktree (`linked_worktree_source`).
- Detached lanes use `git worktree add --detach` then `herdr worktree open` — WHY: `herdr worktree create` invents a branch when given none.
- Lanes keep the workflow's paths — WHY: herdr's default directory is on another filesystem, which breaks repos that depend on their location.
- `--trust-repository` is never passed — WHY: herdr reserves it for a human decision.
- The panel reads only local state, never the board — WHY: board reads take 10-20 s each and exhaust the shared GraphQL limit. The human decided this after testing a board-backed panel. `board.sh show` and `list` also have side effects a poller must not trigger: the comments-read marker and queue replay.
- State lives in the git common dir, not `.claude/` — WHY: every worktree shares it, it cannot be committed, and consumers need no new gitignore rule.
- TODO numbers are permanent and seeding is idempotent (new TODOs are appended unless `--before` or `--move` places them; only the order can change, never a number); scope reduction drops a TODO instead of deleting it — WHY: several agents can hold stable numbers and re-seed without losing progress or resurrecting dropped work.
- A TODO stores a permanent `num` and the list order is the display order; `active`/`activeBy` mark work in progress — WHY: `--before` and `--move` put work in the order it happens without changing what `--done 5` means for agents holding old numbers. Records without `num` get it from their positions on read and are written back only on the next write; the panel reads both forms because it does not import `task_state.py`.
- Every agent brief carries a required `## TODO UPKEEP (required)` section — WHY: subagents see only their brief, and a record that claims undone work or cannot show reduced scope misleads the human watching.

### Out of scope
Enabling the integration in a consumer repo, capturing agents' private to-do lists, and reordering panels.
