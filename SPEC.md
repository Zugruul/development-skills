# spec-workflow — development spec (v1)

## §1 Overview

spec-workflow is a Claude Code plugin implementing a config-driven autonomous build workflow: a GitHub Project board as the source of truth, TDD via delegated dev agents behind a hook-enforced quality gate, per-identity agent memory ("brains"), and an autonomous PR review→merge protocol. This spec governs the plugin's **own continued development**, tracked with the plugin itself (dogfood). It consolidates the 2026-07-07 review synthesis and the in-flight work into a buildable backlog.

## §2 Goals

- **G1** — Ad-hoc work (ideas, bugs, requests) can be searched for and captured onto the board from inside a session, with duplicate detection, without leaving the loop (§6).
- **G2** — Every known correctness hole in the enforcement spine is closed with a red-first regression test (§7).
- **G3** — The self-improvement loop is complete and measurable: every learning signal is captured, retros are enforced, proven lessons graduate into enforcement, and loop performance is quantified (§8).

## §3 Non-goals (v1)

- Board providers other than `github-project` (no GitLab/Jira/Linear).
- Multi-repo orchestration (one repo per config; no driving submodules/siblings from one board).
- Embedding/vector-based brain recall — recall stays deterministic (frontmatter match + link-walk).
- A second marketplace plugin (everything lands inside spec-workflow).
- Model evals in the merge gate (advisory only; see §11).
- Eval-coverage expansion for skills (deferred to v2).

## §4 Glossary

- **Loop iteration** — one `build-next` run: pick → implement (dev agent) → verify → review → merge → retro.
- **Gate** — the single merge-gating command; a hook blocks *In review* moves without a recorded, tree-bound pass.
- **Lane** — one concurrently-worked task: own worktree + branch + dev agent (`methodology.maxInProgress` lanes max).
- **Identity / role** — a configured agent persona (dev/reviewer/orchestrator…) with git author templates and an allowed-models list.
- **Brain / note / synapse** — a role's private zettel memory; notes are markdown with frontmatter, synapses are weighted `links.json` edges; recall is spreading activation.
- **Retro** — the orchestrator's PR-close step minting lessons into brains.
- **Graduation** — promoting a proven note into enforcement (ROLE.md rule, `specs[].invariants` entry, or a test/lint) and retiring it from injection.
- **Inbound task** — ad-hoc work captured onto the board outside seed-board.

## §5 Architecture (as built — pointers, not re-design)

Three planes, all projections of `.neural-network/project.yaml` (schemaVersion 2): **decision** (`next.py`, `validate-config.py`, `config.py`), **action** (`board.sh`, `gate.sh`, `seed-board.sh`, `identity.sh`/`identity_lib.py`, `merge-mode.sh`, `brain.py`, `neural-view.py`), **enforcement** (SessionStart + PreToolUse hooks: `session-start.sh`, `guard-board-move.sh` on `tree-state.sh` fingerprints). Protocol references live under `skills/build-next/references/` (auto-review, brains, concurrency). Tests: hermetic `tests/run-tests.sh` + fixtures.

## §6 Workflow UX (E0)

Constraint for all of §6: `board.sh` is the ONLY board access; similarity/dedup logic lives in a script with its own tests, never as prose instructions.

- **§6.1** WHEN `/find-task <query>` is invoked THE SYSTEM SHALL search existing board issues (open and closed) by title and body and print ranked matches with issue number, status, and score.
- **§6.2** WHEN `/create-inbound <description>` is invoked THE SYSTEM SHALL run the §6.1 search first and present likely duplicates before creating anything.
- **§6.3** IF a high-confidence duplicate exists THEN THE SYSTEM SHALL NOT create a new issue without explicit confirmation (default: comment on the existing issue instead).
- **§6.4** WHEN an inbound task is created THE SYSTEM SHALL mark it as inbound with the GitHub label `inbound` (Status stays `Backlog`, no dedicated inbound status column), assign a priority, and add it to the board so `next.py` can pick it.
- **§6.5** WHERE the match confidence is medium THE SYSTEM SHALL follow the user's OQ-4 decision (default: ask the human).

### §6.6 Project inventory

WHEN the human invokes `/neural-network-projects-list`, the system SHALL enumerate
anchored immediate-child repositories under the selected scan base (default
`~/Development`) using discovery shared with neural-view and sync-configs, and
SHALL always include the selected current repository (default cwd Git root,
falling back to cwd), even when its anchor or config is absent. The inventory
SHALL deduplicate canonical paths and sort rows deterministically. Unreadable
scan bases or children SHALL not abort other repository rows.

FOR EACH repository, the system SHALL report its path, `project.name`, schema
semver detected from raw config using the shared version detector, methodology
`maxInProgress`, `autoMerge`, `serialDelivery`, feedback enabled (including boolean
shorthand), `iterativeUI`, and every configured board provider/project number.
Absent settings SHALL remain unspecified rather than receiving guessed defaults.
Config selection SHALL use the shared canonical YAML/YML/legacy JSON loader
behavior independently of ambient `PROJECT_CONFIG`.

WHEN a repository config is missing, unreadable or invalid, the inventory SHALL
retain its row as `INVALID`, include the actual validator's first error when
available (otherwise an explicit load/validator-failure diagnostic), and continue
with other rows. Safely readable fields SHALL be retained. Valid rows SHALL show
`OK`. The command SHALL support a compact textual table and structured `--json`
output; invalid rows SHALL not cause inventory failure.

The operation SHALL read local filesystem data only and SHALL NOT create anchors,
edit config, write caches/bytecode or fetch board/network data. The skill SHALL
use the same engine on Claude and Codex with plugin-root resolution from the
installed skill location, preserving existing host discovery metadata and existing
scanner-specific fallback, explicit-root and self-exclusion policies.

### §6.7 Herdr integration

WHERE the project config has a top-level `herdr` object, the system SHALL accept
only the keys `enabled`, `worktrees.taskLanes` and `worktrees.subagents`, each a
boolean, and `validate-config.py` and the schema SHALL reject unknown keys and
non-boolean values. `enabled` SHALL default to off, `worktrees.taskLanes` SHALL
default to on while `enabled` is true, and `worktrees.subagents` SHALL default to
off. WHEN the `herdr` object is absent, THE SYSTEM SHALL NOT call herdr.

WHEN `scripts/herdr-worktree.sh add` or `remove` is invoked and herdr task lanes
are enabled, THE SYSTEM SHALL create or remove the task-lane worktree through
herdr, for branch lanes, detached lanes and explicit paths, from any checkout of
the repository, SHALL NOT move focus, and SHALL NOT pass `--trust-repository`.
`implement-task` and `build-next` SHALL create and remove their lanes through
this helper. Without `--base`, a new branch lane SHALL start from the invoking
checkout's HEAD, and `remove` SHALL succeed when run from inside the lane it deletes.

WHEN herdr is missing or fails, or answers success but did not create or remove
the worktree, THE SYSTEM SHALL fall back to git with a notice that names the real
reason, and SHALL NOT block the work. Herdr SHALL start only from the primary
checkout, found from the git dirs; when there is none (a bare repo), git makes the
lane. `remove` SHALL use herdr
whenever herdr is enabled and a workspace is open for that path, even with `worktrees.taskLanes` off, so no "(deleted)" sidebar
entry is left. The hook SHALL always exit 0 and print nothing, and an unreadable
config SHALL count as off. Errors reported by git itself SHALL still fail, and
a lane path that is already in use SHALL be refused.

WHEN an isolated subagent starts and `herdr.worktrees.subagents` is enabled, THE
SYSTEM SHALL open its worktree in herdr from the `SubagentStart` hook, and WHEN it
stops SHALL close that workspace from the `SubagentStop` hook, without using
`WorktreeCreate`. WHEN the setting is off, or the subagent is not isolated, THE
SYSTEM SHALL make no herdr call and print nothing. THE SYSTEM SHALL NOT close a
workspace it did not open. THE `SubagentStop` hook SHALL close by agent id alone, so a stop whose
working directory is a subdirectory still closes the workspace the start opened.

WHEN the herdr tasks panel is toggled, THE SYSTEM SHALL open or close it for the
current tab only, open it to the right without moving focus and narrow it, read only local task
state, make no network call, and strip control characters from task text before
display. A record of the wrong shape (the shape `task_state.py` accepts) SHALL be listed as
unreadable without hiding other tasks, a herdr reply of an unexpected shape SHALL NOT
stop the panel, Ctrl-C SHALL quit it even from a background job, and a live panel whose herdr lookup fails SHALL keep its record.

### §6.8 Task state

THE SYSTEM SHALL keep one record per task under `<git common dir>/spec-workflow/
task-state/`, shared by every worktree of the repository, holding the task id,
title, status, agents, worktrees and numbered TODOs. Concurrent writers SHALL NOT
corrupt a record. TODO numbers SHALL stay stable, and seeding the same TODOs again
SHALL change nothing.

WHEN an agent works a task, THE `implement-task` skill and the parallel-lane
documentation SHALL instruct it to maintain that record through
`scripts/task-state.sh`.

WHEN work leaves a task's scope, `task-state.sh todo --drop` SHALL keep the TODO in
the list with its number, show it as `[-]`, and leave it out of the done and total
counts in `show`, `list`, `describe` and the herdr tasks panel. `--undo` SHALL
restore a dropped TODO to open, `--done` on a dropped TODO SHALL be refused, and
seeding the same TODOs again SHALL NOT bring a dropped TODO back.

WHEN an agent begins a TODO, `task-state.sh todo --start` SHALL mark it active with
the agent's role; `show` SHALL print `[>]` and the role, `--done`, `--undo` and
`--drop` SHALL clear the mark, and several TODOs MAY be active across agents. THE
tasks panel SHALL draw an active TODO bold, not dimmed, and add a wrapped
`Now: <text> · <agent>` line per active TODO under the task header.

THE list SHALL read in the order the work happens. Every TODO SHALL carry a
permanent number, so `--done 5` always means the same TODO. `todo --add TEXT
--before REF` SHALL insert ahead of REF, `todo --move REF --before REF` SHALL
reorder, new TODOs SHALL get the highest number plus one, and `show` SHALL list
permanent numbers in display order. A reference is a number or exact text, and an
unknown one SHALL be refused with exit 1. A stored number that is not a positive
integer SHALL make the record unreadable. `--add` of text that already exists SHALL
add nothing, name the existing TODO's number on stderr, and exit 0. A record written before numbers were
stored SHALL get them from its positions on read, without being rewritten by a
read, and `set --todo` SHALL still append only what is new.

EVERY agent brief the workflow writes (the dev brief, each review-pass brief and the
auto-review reviewer brief) SHALL carry a required `## TODO UPKEEP (required)`
section. It SHALL tell the agent to tick a TODO when it is finished, one at a time;
to `--add` new work and `--drop` work that leaves scope when that happens; to `--start` a TODO when beginning it and not leave it set, to insert new work
with `--before` where it happens (normally ahead of the gate, review and merge items,
never at the end by default, with a re-gate staying after the fix), to `--undo`
every TODO a failed check or finding makes untrue before starting the fix, and re-tick
only after the redo; and, for reviewers, to record a finding as a TODO or a reopening.
THE tasks panel SHALL NOT claim something a regression has undone.

WHEN `board.sh move` changes a task's status, THE SYSTEM SHALL update the status of
an existing record, and SHALL remove the record WHEN the new status is past review
(a status after the third in the board's `statusFlow`, compared ignoring case and
spacing). Backlog and the working statuses SHALL keep it.
THE SYSTEM SHALL NOT create a record from a move, and a missing, unreadable or
corrupt record SHALL NOT make the move fail. `task-state.sh list` SHALL skip a
corrupt record, including valid JSON of the wrong shape, with a notice rather than
fail, and `show`, `set` and `todo` SHALL refuse it rather than crash or overwrite.
`todo` SHALL refuse an empty reference or text with a clear error.

## §7 Hardening (E1)

- **§7.1 tree-state** — WHEN untracked files exist in the working tree THE SYSTEM SHALL include their content hashes in the gate fingerprint, so editing an untracked file after a green gate invalidates the recorded pass.
- **§7.2 guard-board-move** — WHEN a `board.sh comment` (or any non-`move` subcommand) whose text contains a status name is executed THE SYSTEM SHALL NOT block it; the guard SHALL key on the parsed subcommand and target status, not substrings. Root resolution: see "§7.2 guard-board-move root resolution" below.
- **§7.3 next.py** — WHEN a `blockedBy` epic has zero seeded tasks THE SYSTEM SHALL remain fail-closed AND report `epic <id> unseeded — run seed-board` (never the misleading "not fully <status>").
- **§7.4 board.sh** — WHEN a board or issue list exceeds one API page THE SYSTEM SHALL paginate until exhausted; no silent 400/500-item truncation in `next`, `list`, `move`, or seeding. Project-item reads: see "§7.4 Board pagination" below.
- **§7.5 test flakes** — WHEN a server-lifecycle check fails in `run-tests.sh` THE SYSTEM SHALL retry it once and report the flake distinctly (closes issue #8); server-lifecycle sections SHALL use per-run randomized ports.
- **§7.6 brain.py** — WHEN a tag contains both an embedded double-quote and a comma THE SYSTEM SHALL round-trip it intact through `render_note` (escape on write, unescape on parse).

### §7.2 guard-board-move root resolution

WHEN a Bash command contains a `board.sh move <n> "In review"` segment, THE SYSTEM SHALL
resolve the tree whose recorded gate pass is checked from the directory a shell would really
run that segment in, not only from the hook's ambient cwd. It SHALL honour a `cd <path>` only
when the cd is the first command of its own segment and sits directly before the board.sh
segment, joined by `&&` or `;` (or a newline): `cd P && board.sh move ...`,
`cd P; board.sh move ...`, also inside a `bash -c` string. With no such prefix the behaviour
is unchanged.

The resolution SHALL fail closed. A cd target the guard cannot resolve literally (a variable,
command or backtick substitution, a glob or brace expansion, `~`, `-`, a `cd` with options,
an empty target, a path that does not exist or is not inside a git checkout) SHALL be ignored
and the ambient root used, so the move is blocked unless the ambient tree truly has the pass.
A relative target SHALL resolve against the ambient cwd, and SHALL be honoured only when the
cd is the very first command of the line (or of its `bash -c` string, with nothing before the
`bash -c`) and `CDPATH` is not set in the hook's environment, because any earlier command
(`eval`, `source`, a `CDPATH=` assignment, an indirect cd) may have changed the directory
unseen. No cd SHALL be honoured when the command contains a carriage return or the guard's
internal sentinel character, follows a comment, heredoc or `function`, `for`/`select`/`repeat` (zsh runs them with an empty list or count 0), a paren (a `f()` definition, group or subshell), literally redefines `cd`, or
comes after an operator continued by a newline, also a backslash-newline (`true ||<NL>cd P; board.sh ...`). A
non-numeric issue number never carries a cd target. `bash <path>/board.sh move ...` after
the cd is the same segment as `board.sh move ...`. A `cd` that does not govern the board.sh segment (`cd P && echo hi; board.sh ...`,
`cd P || board.sh ...`, `true && cd P; board.sh ...`, a pipe or subshell, an env-assignment
prefix between them) SHALL NOT be honoured. Shell operators inside quotes or heredoc bodies
are data and SHALL NOT count.

Resolving the root SHALL NOT widen what passes: the fingerprint SHALL still be computed for
the resolved tree and compared with the recorded pass, so a cd to a tree whose state differs
from the recorded pass is blocked, and a cd to a clean sibling does not pass with another
tree's fingerprint. Non-`move` commands are unaffected.

Every BLOCKED message of the gate check (`gate-preflight.sh`, shared by the hook and
`board.sh`) SHALL name the tree root it fingerprinted and the marker path it read, so a root
mismatch is visible. The serialDelivery check for `board.sh move <n> "In progress"` SHALL
resolve its primary root (config and `board-cache.json`) from the same cd rules, and from a
linked worktree SHALL still read the primary checkout's state.

Known limit: a literal parser cannot see an `alias cd=:`, an `eval 'cd() { :; }'`, an
exported `cd` function, `enable -n cd` (bash) or `disable cd` (zsh), nor a `CDPATH` set only in
the shell profile (the hook's own environment is checked, the shell's startup files are not). A cd made unreliable that way can still be honoured, so the guard is
the fast layer only; `board.sh`'s own gate check (`gate-preflight.sh` in the move path) is the
backstop that judges the tree the move really runs in.

### §7.2 board.sh ensure-issue (#565)

WHEN the orchestrator is about to open a PR (or, under `work.type: local`, merge directly to
main) that has no picked task, THE SYSTEM SHALL provide `board.sh ensure-issue --title "<title>"
[--for-branch <branch>] [--body-file F] [--prio P2]`, which prints on stdout only the issue
number to use, and a human line on stderr.

It SHALL return an existing issue when one is linked: first, when `--for-branch` matches
`project.branchPattern`, the `<id>` of the branch if that issue exists (one REST
`GET repos/<repo>/issues/<id>`, and the result SHALL NOT be a pull request); second, an open
PR for that branch (one REST `GET repos/<repo>/pulls?head=<owner>:<branch>&state=open`) whose
body has `Closes/Fixes/Resolves #N`. Otherwise it SHALL create an inbound issue through
`board.sh add --type inbound` and print its number. `--body-file` sets the new issue body with
one REST PATCH. The lookup SHALL use REST only: no GraphQL and no full-board read.

It SHALL never stop work. WHEN `board.sh add` queues the board placement (rate limit), it SHALL
still print the created issue number and say QUEUED on stderr. WHEN no issue can be created it
SHALL print a clear line on stderr, print nothing on stdout, and exit 0; that line SHALL say
what to do next: keep working, commit the branch (push it too under `work.type: pr`),
retry board.sh ensure-issue after the rate-limit reset, then open the PR with `Closes #N`. The skills
build-next and implement-task SHALL say the same. Only invalid arguments exit 2 (missing or
multi-line `--title`, a `--prio` not among the board's configured priorities).

The issue number SHALL be taken only from `board.sh add`'s own creation lines, never from the
title it echoes. Every created issue SHALL get a truthful body through one REST PATCH: the
`--body-file` content, else "Filed by board.sh ensure-issue for branch <B> / title <T> so the
work has a board card."; a missing `--body-file` warns. The open-PR lookup SHALL pass the branch
as a gh `-f head=<owner>:<branch>` field (gh URL-encodes it) and accept `Closes/Fixes/Resolves
#N` or `<repo-name>#N` outside fenced code; the found number is not re-checked as an issue (that
would cost another call). A failed (non-404) lookup of the branch id SHALL trust the id with a
warning rather than file a duplicate; a closed id is reused with a warning; an id that is a pull
request is rejected. The default body SHALL put the branch and title in code spans. WHEN `--prio`
is absent it SHALL be P2, or the middle configured option (said on stderr) when P2 is not
configured. WHEN the board config cannot be read it SHALL warn on stderr and carry on without the
branch-pattern and priority checks (never stop work).

### §7.2 guard-pr-create (#565)

THE SYSTEM SHALL word the block message of `guard-pr-create.sh` (missing reference, or no
`--body`/`--body-file`) so that it points at `board.sh ensure-issue`. The skills build-next and
implement-task SHALL state that every orchestrator PR goes through `ensure-issue` first with
`Closes #N` in its body, and that a `work.type: local` direct merge to main without a task runs
`ensure-issue` and puts `#N` in the merge commit subject.

### §7.3 next.py (#567)

WHEN `board.sh next` runs and the item list it already fetched holds items in QA (the fourth
entry of the board's statusFlow; a flow with fewer entries reports nothing), THE SYSTEM SHALL
print `STALE QA: #N in QA for 3d — validate and move on, or record why not` for each such item
whose latest local telemetry `transition` into QA is older than `methodology.qaStaleHours`
(positive integer, default 24; days from 48 hours, hours below). Known ages SHALL print
oldest first, at most 5 lines, then `STALE QA: +N more`. Items with no local record, or whose
latest transition into QA has an unreadable timestamp, SHALL fold into ONE line
`STALE QA: N items with age unknown: #a, #b, ...` (ids capped at 5, then `+N more`); an older
valid entry SHALL NOT be used instead of a malformed latest one.

The report SHALL be advisory, board-wide (`next <spec-id>` does not narrow it), printed on pick,
resume and wait paths alike, and SHALL make zero additional GitHub calls. A failure to read the
log SHALL NOT fail `next`.

### §7.4 Board pagination

WHEN the system reads project items (every `next`, `list`, `move`, `audit`, `flush`
and seeding read) it SHALL do so through a slim, cursor-paginated `gh api graphql`
query, not `gh project item-list`. The query SHALL resolve the owner with
`repositoryOwner(login:) { ... on ProjectV2Owner { projectV2(number:) } }` (or
`viewer` for an `@me` owner), so user- and organization-owned projects share one
call with no owner-type lookup. It SHALL request only the fields callers use
(`Status`, `Priority`, `Estimate` through `fieldValueByName` aliases, plus content
number, title, body, url, repository and labels) and SHALL NOT request
`fieldValues(first:100)` or any other nested connection per item, with one named
exception: `labels(first: 20)` on the content (kept so the output keeps the
`gh project item-list` shape; no current caller reads it; items with more than 20
labels are truncated to 20; the measured cost below includes it). Its output SHALL
keep the JSON shape of `gh project item-list --format json`
(`{"items":[{id,title,status,priority,estimate,labels,repository,content:{type,number,title,body,url,repository}}],"totalCount"}`;
absent field values are omitted).

`fieldValueByName` matches names case-sensitively while project field names are
case-insensitive in config and gh, so before the items query the system SHALL
resolve the project's real Status, Priority and Estimate names case-insensitively
(one extra query, 1 point) and use them in the aliases; output keys stay lowercase.
WHEN the project has no Status field a strict read SHALL fail closed (`WIP BLOCKED`);
any other read SHALL warn on stderr and return items without a status, as
`gh project item-list` did. A missing Priority or Estimate field is not an error.

Pagination SHALL follow `pageInfo.endCursor` until `hasNextPage` is false, which is
the only proof of exhaustion. No page SHALL be read twice; the former `--limit`
doubling re-read is removed for project items (`gh_issues_json` is unchanged).
A read that cannot progress SHALL fail: `hasNextPage` true with an empty page, or any
cursor seen twice in one read. Any nonzero `gh` exit is a failed read. `PAGINATE_HARD_CAP` remains a backstop counted in items: reaching it with
`hasNextPage` still true SHALL warn on stderr (non-strict) or fail with
`WIP BLOCKED` (strict).

Nothing SHALL be written to stdout until every page has been read. An error on page
N SHALL return nonzero with empty stdout, never the earlier pages. `--strict` reads
SHALL additionally validate the merged snapshot (unique item identities,
`totalCount` present and equal to the items read) and fail closed on any error or
incomplete read.

Cost (measured with `rateLimit(dryRun: true) { cost }` against the real boards of
owner Zugruul, 2026-11-05): one 100-node page of the final query costs 1 GraphQL point on project 5 and
on project 12, and the field-name query costs 1 point (live `rateLimit { cost }`). A full read costs
`ceil(items / 100) + 1` points: project 5 (428 items, `totalCount` from one real read) = 6
points, against 911 points for `gh project item-list` on the same board; a 280-item board = 4
points, against 304.

### §7.4 board.sh agent (#566)

WHEN `board.sh agent <n> <name>` runs, THE SYSTEM SHALL label issue `n` `agent: <name>` so the
board shows who is working on the card. The name SHALL be lowercased, characters outside
`[a-z0-9._-]` replaced by `-`, and the whole label truncated to 50 characters (GitHub's limit),
deterministically. Any other `agent: *` label on the issue SHALL be removed first, so a re-brief
replaces the label rather than adding one. `board.sh agent <n> --clear` SHALL remove every
`agent: *` label.

The command SHALL use REST only (`gh api repos/<repo>/issues/<n>/labels`, `repos/<repo>/labels`),
never GraphQL and never `gh project`. Budget: one GET, one DELETE per stale agent label, and one
POST per set (none when the label is already set). A missing label SHALL be created through
`POST repos/<repo>/labels` (a 422 `already_exists` tolerated) and the set retried once.

The label is cosmetic: a failed read, create, set or remove SHALL print a warning and exit 0, and
a rate limit SHALL print that it was hit and exit 0 without queueing. Only invalid arguments
(non-numeric issue, missing or empty name, unknown flag) SHALL exit 2.
Skills SHALL run it after naming the dev agent at spawn and at re-brief, and `--clear` at merge or
abandon.

### §7.7 board.sh rate-limit resilience (#77, #561)

This block restates the WHOLE final §7.7. Only the paragraph that started "WHEN a board read
fails for a reason other than a rate limit" (the `DEFERRED` stop) is replaced; everything else
is unchanged from SPEC.md except the new queue rules.

WHEN a board read is rejected by GitHub THE SYSTEM SHALL report GitHub's own error
(for GraphQL, the `errors[]` message and type, e.g. `RATE_LIMIT` /
`graphql_rate_limit`), including a 200 response that carries `errors`, instead of
`unknown owner type`. `_rate_limited` SHALL recognize that payload by its text or
code without consulting `gh api rate_limit`, because one token has two GraphQL
counters and the REST endpoint can show quota while requests are rejected. The
`unknown owner type` probe remains for the `gh project` write commands
(`item-edit`, `item-add`, `field-list`).

The reset time in `RATE-LIMITED until <reset>` and `QUEUED (rate-limited until
<reset>)` SHALL come from the rejected response's `X-Ratelimit-Reset` (or
`Retry-After`) header when present and still in the future, adding no API call; it
falls back to `gh api rate_limit` otherwise. `Retry-After` (what applies on a secondary
limit, and can be far later) takes precedence over `X-Ratelimit-Reset`. The saved reset
is private to the invocation (a per-run temporary file removed on exit), so another
run's or account's rejection is never reported. Header parsing SHALL NOT alter the JSON
written to stdout. The error `code` (e.g. `graphql_rate_limit`) SHALL be part of the
reported message, so a reworded payload is still classified.

WHEN a board read fails for a reason other than a rate limit, THE SYSTEM SHALL print GitHub's error and SHALL NOT report a bad issue number; `adopt`/`add` SHALL NOT `item-add` on a read failure (a failed read is not "not on the board"). The work is queued instead of stopped (below).

Rule from the human (2026-11-09): never stop work because a card could not move; queue
the update and apply it as soon as possible.

WHEN `board.sh move` fails for a reason that is not a guard refusal and not a rate limit
(a 5xx or other transient API error, a timeout, a network error, an incomplete board
snapshot while admitting to a WIP status, a busy admission mutex), THE SYSTEM SHALL append
the move to the local queue with a `reason`, print `QUEUED (<reason>): move #N -> <status>`
and exit 0. A rate limit keeps `QUEUED (rate-limited until <reset>)`. A guard refusal
(checkpoint, gate-preflight, red-first, design-registry, two-pass-review, closure,
comments-not-read, a bad status, a WIP `capacity X/Y occupied` refusal) SHALL NOT be
queued: it prints and exits non-zero as before.

`_do_move` returns 0 applied, 1 guard/validation refusal, 2 rate-limited, 5 retryable.

WHEN any later `board.sh` call runs (`move`, `adopt`, `next`, `list`, `show`, `flush`),
THE SYSTEM SHALL replay the queue once, oldest first, under the flush lock. Per move entry:
a move superseded by a newer applied move of the same issue is skipped (printed); the local
guards (checkpoint, gate, red-first, design-registry, two-pass review, closure, comments
read) run BEFORE any board read, so a guard-refused entry costs zero gh calls per call; a
guard refusal that can still clear keeps the entry queued; a status missing from
`statusFlow` drops it with `flush: DROPPED move #N -> <status>`. A rate limit stops the pass.

Replay SHALL read the board at most once per flush, WIP-status moves included. When the
queue holds any WIP-counted move the flush takes the WIP admission mutex FIRST, before its first
board read, then reads the snapshot, and holds the mutex until the pass ends (lock order flush -> WIP). WIP
admission reuses that snapshot, which is patched after each applied move so capacity stays
right. Because the mutex is held, a live start cannot be admitted between the snapshot and an
admission (no over-admission); live moves wait (bounded) and queue as `admission mutex busy`. A
mixed queue therefore still costs one read. A holder whose pid is dead is broken (atomic rename, pid re-checked); a live
holder never is.

Retry policy. A transient failure (rate limit, HTTP 5xx, timeout, network) retries until it
applies, and a timeout or network failure stops the pass like a rate limit. A failure that
belongs to ONE entry with an unrecognised label (`gh error`: an `item-edit` error such as
"Could not resolve to a node", an `item-add` failure) is counted in the entry (`attempts`); on
the 5th attempt it is dropped with
`flush: DROPPED <op> #N after 5 attempts (<reason>) — fix and re-run board.sh <op> N` (a move
shows `board.sh move N "<status>"`, an `add-finish` points at `adopt`). During a replay an
unrecognised `item-edit` error does not trigger the stale-id full-board re-read (the id came
from the fresh snapshot). `prio` and `est` entries take the same path (snapshot first, attempts, board-wide stop). A BOARD-WIDE
read failure (the snapshot, or an `add-finish`/`adopt`
lookup: 401, "Could not resolve to a ProjectV2", timeout) belongs to no entry: it never counts
attempts, stops the pass, keeps every entry and prints one line
`flush: board read failed (<reason>) — queue kept`, so an auth outage cannot empty the queue.
A recognised transient label is not probed with `gh api rate_limit`.

A LIVE `board.sh move` that fails with an unrecognised gh error (or an unreadable snapshot) is
queued too, with `attempts=1`, printing `QUEUED (gh error): move #N -> <status>` and exiting 0
(work never stops on a card), like `add` and `adopt`; WIP and non-WIP moves use the same label
(`board read failed: <label>` for an unreadable board). `add` and `adopt` whose read-back fails after a
successful `item-add` also queue (with the read reason) and exit 0. Guard refusals still exit non-zero.
A flush whose queue-file lock stays busy skips the pass untouched. Dedupe ranks by `seq`.

A direct move that applies SHALL write a supersede marker for the issue and remove older
queued moves of it under a short queue-file lock (bounded wait). The marker time is taken right
after the apply returns, so a move queued after the apply is never dropped. The lock breaks a
dead holder at once (pid probe), a pidless one after 30 s, never a live one, and the break is an
atomic rename. A writer that cannot get the lock after two bounded waits appends to an atomic
spool file that the next flush merges, so nothing is lost and nothing is written unlocked next
to a rewrite. A flush that already moved the queue aside honours the marker.

A move whose terminal status (Ready, Deployed) has no closure evidence yet stays queued and
shows as a `PENDING` line until the retro (or a retro-skip) is recorded; the replay checks the
guard before it checks whether the status already holds.

WHEN `add`'s `gh project item-add` exits non-zero for a reason other than a rate limit,
THE SYSTEM SHALL queue the idempotent `add-finish` op (which re-checks presence first),
print `QUEUED (<reason>): item-add #N` and exit 0, instead of claiming the issue is not
on the board (it often is). `adopt` does the same with an `adopt` op.

`board.sh next` and `board.sh list` SHALL print each queued move as
`PENDING: move #N -> <status> (queued <age>, <reason>)`, as does `board.sh pending`. The
display reads the local queue file only and makes no gh call.

Round 4. During a replay, "not on the board" is decided from the fresh snapshot itself (no second
read) for `move`, `prio` and `est`; it counts attempts and is dropped on the 5th with
`board.sh adopt N` as the hint. A failed read-back after a good `item-add` queues an `adopt` op:
replay re-checks membership, re-adds when absent, and sets the first status only when the status is
empty, so a card a human moved meanwhile is untouched (`adopt` of a card already on the board with
an empty status now sets it). The WIP mutex pre-scan only counts entries that will really be
attempted (not superseded, not paused, not guard-refused). `bug` recognises only its own issue's
`QUEUED (...): move|prio #N` lines.

Newest wins (independent review 1). The queue keeps only the NEWEST move per issue at replay
start (ranked by `seq`); an older `--over-wip` move never overrides a newer plain one, and its
flag is carried onto the newest move only when both target the same status. A move applied
during replay writes a supersede marker with that entry's `seq` and removes older queued moves of
the issue, and `_superseded` is re-checked right before the apply. `add-finish` sets the first
status only when the card has none, so a card that was moved meanwhile (directly or by an agent)
is never put back; the same rule already holds for `adopt`.

Bounded queue. A queued `prio` or `est` with an invalid option or a missing item can never
apply: replay drops it with `flush: DROPPED prio #N (invalid value or item, see above)`. An entry
that failed retryably 3 times in a row (HTTP 5xx, incomplete snapshot, busy mutex) records
`fails` and `last_try` and is replayed at most once per 10 minutes (BOARD_QUEUE_BACKOFF_SECS), at
zero gh calls in between, so polling by `list` does not spend a read and an edit per poll.


Known limits: a `Retry-After` given as an HTTP date (instead of seconds) is ignored and the
primary reset is used; a project with more than 100 fields (the `fields(first: 100)` page) may
hide Priority/Estimate or Status, in which case Status is reported missing and strict reads
fail closed. Several Status fields differing only by case (`status` and `Status`) are
ambiguous: strict reads fail closed; other reads warn and use the exact-case `Status` field if
it exists (otherwise Status is unresolved). Whether GitHub allows such duplicates was not
checked.

### §7.9 Checkout preservation at startup

- **§7.9.1 Inspection** — WHEN a build iteration starts THE SYSTEM SHALL inspect the actual checkout selected by cwd or explicit root before switching branches, pulling or implementing. The shared read-only `checkout-preflight.sh` command SHALL report deterministic JSON containing the checkout path, a `clean`, `dirty` or `uninspectable` status, and a routing action; clean SHALL exit 0, dirty SHALL exit 1, and uninspectable SHALL exit 2. WHEN dirty THE SYSTEM SHALL include safely escaped paths and Git status codes for staged, unstaged, deleted, renamed, unmerged, untracked and submodule changes regardless of Git status hiding preferences; ignored files SHALL remain ignored. WHEN inspection fails THE SYSTEM SHALL report the error and SHALL NOT infer cleanliness.
- **§7.9.2 Preservation** — WHILE inspecting a checkout THE SYSTEM SHALL disable optional index writes and SHALL preserve HEAD, index, worktree bytes and stashes, without consumer temporary files, network requests or automatic stash, reset, add, commit or cleanup. All pre-existing changes SHALL be treated as unowned. The inspection SHALL be documented as a point-in-time observation, not an ownership registry or cross-process lock.
- **§7.9.3 Routing** — WHEN inspection reports clean THE SYSTEM SHALL return `proceed`. WHEN it reports dirty AND the session has authorized worktree isolation THE SYSTEM SHALL return `isolate`; otherwise it SHALL return `pause`. WHEN it reports uninspectable THE SYSTEM SHALL return `stop` and SHALL stop checkout mutation. An explicit main-only session SHALL require the human's choice before isolation; existing session authorization SHALL be reused without repeated permission requests.
- **§7.9.4 Isolation** — WHEN the startup decision is `isolate` THE SYSTEM SHALL preserve the original checkout, fetch the configured remote main without switching that checkout, resolve the fetched commit, and create a new clean sibling orchestration worktree from that verified base; WHERE no remote exists THE SYSTEM SHALL use local main. WHEN fetch, ref resolution or worktree creation fails THE SYSTEM SHALL stop and retain recovery details rather than fall back to stale or dirty state. THE SYSTEM SHALL inspect the new lane before switch/pull or implementation and follow register-first task creation from the verified base. A dirty primary checkout SHALL NOT block a separately verified clean linked checkout.
- **§7.9.5 Advisory integration** — WHEN advisory preflight encounters dirtiness THE SYSTEM SHALL surface `CHECKOUT ACTION REQUIRED` and the checkout decision while retaining its always-zero skill-load contract and independent config/ignore freshness checks. WHEN checkout inspection is uninspectable THE SYSTEM SHALL emit `PREFLIGHT FAIL` and SHALL NOT report preflight ok. The build-next and implement-task protocols SHALL obey the tested shared routing decision before checkout mutation; this SHALL NOT be represented as enforcement of arbitrary Git commands.

### §7.10 WIP admission — over-WIP moves and separate limits (#560, #563)

The WIP limit stops the loop starting too much work; it never hides work that is already running.

WHEN `board.sh move <n> <status> --over-wip "<reason>" [--over-wip-by <who>]` targets a counted
status whose pool is at its limit, THE SYSTEM SHALL apply the move anyway, post exactly ONE issue
comment (the reason, the occupancy `<occupied>/<limit>` and who asked; `<who>` defaults to
`orchestrator`) and record the overage in `.claude/over-wip.json` under the primary checkout root.
WHEN the pool is under its limit, or the target status is not counted, the flag SHALL change
nothing beyond applying the move (no comment, no record). Without the flag, a move at the limit
SHALL be refused exactly as before. `--over-wip` or `--over-wip-by` without a value SHALL fail
before any board call.

The over-WIP path SHALL add no board query: it reuses the snapshot admission already reads, and
its only extra GitHub call is the single comment, posted over REST (`gh api -X POST repos/<repo>/issues/<n>/comments`). WHEN that comment fails the system SHALL warn and keep the move and the record.

`board.sh next` SHALL print `OVER WIP <occupied>/<limit>: #N (<reason>)` for each recorded issue
that is still in a counted status while its pool is over the limit, using the local record and the
item list it already has. It SHALL drop a record once the issue left the counted statuses or the
pool is back at or under the limit. It SHALL keep refusing to hand out new work while over the limit.

Optional `methodology.wipLimits: {inProgress: N, inReview: M}` (integers >= 1, at least one key, no other keys; an empty mapping is invalid)
gives each status its own limit. Absent, `maxInProgress` stays one shared limit across the counted
statuses. Present, a move is admitted against the limit of the status it enters (a missing key falls
back to `maxInProgress`; setting `inReview` counts the review status even without
`serialDelivery`), A move between counted statuses SHALL never be refused. `next` SHALL refuse new work (RESUME) only when In progress is at its `inProgress` limit; WHEN In review is at its `inReview` limit it SHALL print `WARN: <review> n/m is at its limit — finish reviews before starting more` and still hand out work. Under `serialDelivery` without `wipLimits` nothing changes. `next` SHALL print
`WIP: <work> a/N, <review> b/M` and `concurrency.sh status` SHALL show both limits.

Registration steps (implement-task step 0.4, build-next) SHALL pass `--over-wip "<reason>"` when
the human asked for the lane, and a refused or failed move SHALL never stop lane registration or
the work: continue, and report it.

A rate-limited `--over-wip` move SHALL be queued with its reason and requester and replayed with
them; no other queued entry and no inherited environment SHALL carry the flag. Overage records are
keyed `<board>#<issue>`, carry a timestamp, are written atomically under a lock, and a corrupt
record file is moved aside with a warning. `next` SHALL drop only this board's records whose issue
is seen outside the counted statuses or whose pool is back at or under the limit, never for an
issue missing from the snapshot, and never within 10 minutes of the record being written.

### §7.11 Board truth audit (#564)

WHEN `board.sh audit --fix` runs, THE SYSTEM SHALL compare the board with live work and correct it,
printing one line per change: `FIX #N: <from> -> <to> (<why>)`. Without `--fix`, `audit` SHALL keep
its report-only behaviour (exit 1 on any discrepancy) and also list each change `--fix` would make
as `WOULD FIX ...`. With `--fix` the exit SHALL be 0 unless a fix failed.

The rules, per task, with merged winning over review and review over progress:

- A live worktree (under `<root>/.claude/worktrees/`, or on a `project.branchPattern` branch) or an
  open PR, for a card before the work status, SHALL move it to In progress with `--over-wip "audit:
  work is running"`: running work is never hidden by the WIP limit.
- Under `work.type: pr`, an open PR that is not a draft SHALL move the card to In review. Under both
  modes, a live worktree or open PR whose task has `review-round` or `review-round-start` telemetry
  SHALL do the same. The move SHALL run from the
  worktree so the gate and red-first preflights check that tree.
- A merged signal SHALL be ignored when the task has a live worktree or open PR (rework, or work
  split over several PRs), and when it is not newer than the card's last move into work (local
  `transition` telemetry; with none, it counts). A `gate` telemetry event SHALL NOT be a review
  signal.
- Under `work.type: pr`, a merged PR linked to the task SHALL move it to QA. Under `work.type: local`
  (no PRs), a commit on the main branch whose subject ends in `(#N)` (registration, process, `test(`,
  `docs(` and `chore(` commits excluded) SHALL do so for a card in In progress or In review. The move SHALL happen only if
  the two-pass review guard allows it; otherwise the audit SHALL print `NOTE #N: merged but review
  evidence missing — record it or use --accepted-by-user` and SHALL NOT force it.
- A live worktree or open PR with no linked issue SHALL be given one with `board.sh ensure-issue
  --title <PR title or branch> --for-branch <branch>`; the printed issue SHALL be recorded in
  `<root>/.claude/audit-links.json` (branch to issue) and reused by later runs. A link SHALL only be
  that record, the branch's own `<id>`, or a `Closes/Fixes/Resolves #N` in the PR body whose issue is
  on the board; it SHALL never be guessed. An issue the audit files SHALL be marked as comments-read,
  since it has none.

Every move SHALL go through `board.sh move`, whatever that does; a refused, failed or queued move
SHALL be printed and the audit SHALL carry on.

API budget: one full board read per audit (the read the audit already makes, which also refreshes the
cache). With `--fix` it SHALL be a strict read taken under the WIP admission mutex held once for the
pass, and every move SHALL reuse that snapshot (the queue replay's mechanism), patched after each applied
move; a card filed by `ensure-issue` joins the snapshot from the item-id cache. The only other board read
is the visibility poll of `ensure-issue`'s `board.sh add`. A busy mutex SHALL skip the pass with a NOTE; PR lists over REST only (`pulls?state=open&per_page=100`, at most 3 pages, and one
`state=closed` page), none under `work.type: local`; worktrees, branches, commits and telemetry from
local files and git; mutations only through `board.sh move` and `ensure-issue`, each only when a
change is needed. `gh pr list` (GraphQL) SHALL NOT be used. A move into a counted status re-reads the
board for WIP admission, as every such move does.

### §7.11 Board truth audit: --if-due (#564)

WHEN `board.sh audit [--fix] --if-due` runs, THE SYSTEM SHALL do nothing and make no GitHub call
unless the last run is older than `methodology.auditIntervalMinutes` (integer >= 1, default 10),
recorded in the local stamp `<primary root>/.claude/audit-stamp`; it SHALL print one line
(`audit not due ...`). Every detected rate limit SHALL persist its reset epoch to `<primary root>/.claude/rate-limit-reset`
(the rejected response's reset time, else now + 300 s; never shortened). It SHALL also be skipped, with
one line (`audit skipped: rate-limited until ...`), only while that time is in the future; a non-empty
queue alone SHALL NOT skip it. A run
SHALL stamp the attempt, so a failing run does not retry on every tick. `build-next` SHALL run
`board.sh audit --fix --if-due` at each iteration start, and the board skill SHALL describe it.
`--if-due` without `--fix` SHALL be a usage error (exit 2). A statusFlow with fewer than 4 entries SHALL
skip the reconciliation rules with a NOTE. `audit-links.json` SHALL be pruned of branches that no longer
exist. `audit-stamp` and `audit-links.json` SHALL be gitignored local state in `local-state.manifest`.
`validate-config` and the schema SHALL accept `methodology.auditIntervalMinutes` and reject a
value that is not an integer >= 1.

### §7.11 Board truth audit: read-failure backoff (#564)

WHEN three consecutive board-wide reads (`next`, `list`, `audit`) fail for a reason that is not a rate
limit, THE SYSTEM SHALL skip the board read for 10 minutes (one line, no gh call), recorded in
`<primary root>/.claude/board-read-backoff`; a successful read SHALL clear it.

## §8 Self-improvement completion (E2)

- **§8.1 gate capture** — WHEN the gate exits non-zero THE SYSTEM SHALL append the failing command's tail output + timestamp to a local lessons feed (input to the next retro) before clearing the pass marker.
- **§8.2 retro enforcement** — WHEN a PR closes (merge or abandon) THE SYSTEM SHALL require the retro step in `build-next`; skipping SHALL require a stated reason in the iteration report.
- **§8.3 graduation** — WHEN a note's `strength` crosses the configured threshold THE SYSTEM SHALL surface it in `brain.py graduate-check` with a proposed destination (ROLE.md rule / invariant / test-or-lint); graduation itself stays a human-visible retro action.
- **§8.4 telemetry** — WHILE the loop runs THE SYSTEM SHALL append per-iteration records (task id, status transitions with timestamps, gate attempts, review rounds, estimate) to a local telemetry log; `board.sh metrics` SHALL report cycle time per status, first-try gate rate, rework (review-round) rate, and estimate-vs-actual calibration.
- **§8.5 loop feedback**
  - **§8.5.1 emission** — WHEN a build-loop iteration ends AND `methodology.feedback` is enabled THE SYSTEM SHALL collect structured feedback about the WORKFLOW (never the project being built) as a `loop-feedback` record — `schemaVersion`, `ts`, `iteration` (task, outcome, reviewRounds), `source` (role, model), and one or more `items[]` each carrying `category` (worked-well/friction/incident/recommendation), `area`, `severity`, `summary`, and a `generalized` restatement — and append it to the configured feed (`methodology.feedback.feed`, default `.neural-network/feedbacks/feed.yaml`).
  - **§8.5.2 generalization contract** — THE SYSTEM SHALL enforce, at emission time, that project specifics never leave the feed: an item's `generalized` field, when non-empty, together with its `summary`, SHALL NOT contain the iteration's own task id or a `#<digits>` issue/PR reference; such a record SHALL be rejected with an actionable error rather than appended. An item whose `generalized` field is empty SHALL be treated as local-only and SHALL be routable only as `ignore`.
  - **§8.5.3 triage** — WHEN a retro runs THE SYSTEM SHALL triage every unrouted feedback item (no `routing.action` set): dedupe its `generalized` text against existing backlog issues, then assign exactly one routing action — `backlog` (a new board issue is created from the generalized text only, marked `from-feedback`), `brain-note` (folded into the existing retro brain-minting protocol — never a second minting path), `graduate`, `upstream` (surfaced to a human once), or `ignore` (with a stated reason) — and record that action back onto the item.
  - **§8.5.4 explicit consent for backlog routing** — `methodology.feedback.autoTriage` SHALL default to `false`; WHILE it is false, routing an item to `backlog` SHALL require explicit human consent before the board issue is created, mirroring `methodology.autoMerge`'s consent model. WHEN `autoTriage` is `true`, backlog routing MAY proceed without a per-item check-in.
  - **§8.5.5 legacy path migration guard** — WHEN the DEFAULT feed path is in effect (no explicit `methodology.feedback.feed` override) AND a legacy feed exists at `.claude/feedback/feed.yaml` (singular) AND the default path `.neural-network/feedbacks/feed.yaml` does not exist THE SYSTEM SHALL refuse every feed-touching subcommand (emit/pending/route/status) with a nonzero exit and an actionable migration message, rather than silently starting a fresh feed and orphaning the archive. An explicit `feed` override SHALL bypass this guard.

### §8.2 retro enforcement (#567)

WHEN a task is in QA after merge and deploy, THE LOOP SHALL (build-next step 9) run its
validation (acceptance-criteria checks, via `dev-up` when the stack is needed). IF validation
cannot run, THE LOOP SHALL keep the card in QA and record the reason as an issue comment
through the REST API. After the closure evidence and preflight of step 10, THE LOOP SHALL move
QA -> Ready; the closure preflight still gates Ready/Deployed. A refused or failed move SHALL
be reported and SHALL NOT stop the loop.

## §9 Invariants

- Scripts are bash 3.2-compatible, `set -uo pipefail`, and shellcheck-clean.
- Python is stdlib-only; PyYAML is the sole permitted dependency.
- Scripts decide; the model obeys — decisions live in tested scripts, never prose.
- `board.sh` is the only board access; no raw `gh project` calls in skills or agent briefs.
- Brains are orchestrator-mediated only; no role ever reads another role's brain directory.
- Red-first TDD: a failing test commit precedes implementation; the gate is green before *In review*.
- Documentation covered by `docs[]` is updated in the same PR as the behavior it describes.
- Model ids use full nomenclature only (e.g. `claude-sonnet-5[1m]`), never shorthand.
- Agent names are role-prefix-first with a meaningful scope suffix (`dev-sw001`), never bare counters.
- No generic Claude co-author trailers on in-workflow commits; role identities are the attribution.
- The feedback archive (`.neural-network/feedbacks/`) is orchestrator-mediated only, like the identity brains; no dev/reviewer subagent reads or writes it directly.
- The feedback archive is tracked and committed/pushed alongside code by default; opting out requires the repo's own `.gitignore` to exclude it.

## §10 Non-functional

- The hermetic suite completes in under ~2 minutes on a dev laptop.
- All merge-gating tests are deterministic: no wall-clock dependence, no model calls, no network beyond the fake-gh harness.

## §11 Testing strategy

Merge gate = `tests/run-tests.sh` + `shellcheck -x` over all shell + `claude plugin validate` (manifests). Model evals (`claude plugin eval`) are advisory: run on demand, never merge-gating (cost + non-determinism).

## §12 Open questions

| id | question | owner | default if unanswered | status |
|---|---|---|---|---|
| OQ-1 | Inbound tasks: dedicated Status vs a label? | user (decided in the find-task/create-inbound design session) | label `inbound`, Status stays Backlog | **decided**: label `inbound`, Status stays Backlog |
| OQ-2 | New `board.sh add` verb vs generalizing `bug`? | user (same session) | generalize `bug` → `add` with a type flag | **decided**: `board.sh add [--type bug\|feature\|inbound]`; `bug` is a thin alias of `add --type bug` |
| OQ-3 | One capture skill or two (`/find-task` + `/create-inbound`)? | user (same session) | two skills | **decided**: two skills — `find-task` (read side, shipped #10) and `create-inbound` (write side, #11) |
| OQ-4 | Medium-confidence duplicate behavior? | user (same session) | ask the human | **decided**: ask the human via AskUserQuestion; if absent or no answer, do NOT create — print the ranked candidates and the pending description, and stop |
| OQ-5 | Telemetry storage? | orchestrator | `.claude/telemetry.jsonl`, gitignored | open |
