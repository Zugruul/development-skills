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

Three planes, all projections of `.claude/project.yaml` (schemaVersion 2): **decision** (`next.py`, `validate-config.py`, `config.py`), **action** (`board.sh`, `gate.sh`, `seed-board.sh`, `identity.sh`/`identity_lib.py`, `merge-mode.sh`, `brain.py`, `neural-view.py`), **enforcement** (SessionStart + PreToolUse hooks: `session-start.sh`, `guard-board-move.sh` on `tree-state.sh` fingerprints). Protocol references live under `skills/build-next/references/` (auto-review, brains, concurrency). Tests: hermetic `tests/run-tests.sh` + fixtures.

## §6 Workflow UX (E0)

Constraint for all of §6: `board.sh` is the ONLY board access; similarity/dedup logic lives in a script with its own tests, never as prose instructions.

- **§6.1** WHEN `/find-task <query>` is invoked THE SYSTEM SHALL search existing board issues (open and closed) by title and body and print ranked matches with issue number, status, and score.
- **§6.2** WHEN `/create-inbound <description>` is invoked THE SYSTEM SHALL run the §6.1 search first and present likely duplicates before creating anything.
- **§6.3** IF a high-confidence duplicate exists THEN THE SYSTEM SHALL NOT create a new issue without explicit confirmation (default: comment on the existing issue instead).
- **§6.4** WHEN an inbound task is created THE SYSTEM SHALL mark it as inbound (see Open question OQ-1), assign a priority, and add it to the board so `next.py` can pick it.
- **§6.5** WHERE the match confidence is medium THE SYSTEM SHALL follow the user's OQ-4 decision (default: ask the human).

## §7 Hardening (E1)

- **§7.1 tree-state** — WHEN untracked files exist in the working tree THE SYSTEM SHALL include their content hashes in the gate fingerprint, so editing an untracked file after a green gate invalidates the recorded pass.
- **§7.2 guard-board-move** — WHEN a `board.sh comment` (or any non-`move` subcommand) whose text contains a status name is executed THE SYSTEM SHALL NOT block it; the guard SHALL key on the parsed subcommand and target status, not substrings.
- **§7.3 next.py** — WHEN a `blockedBy` epic has zero seeded tasks THE SYSTEM SHALL remain fail-closed AND report `epic <id> unseeded — run seed-board` (never the misleading "not fully <status>").
- **§7.4 board.sh** — WHEN a board or issue list exceeds one API page THE SYSTEM SHALL paginate until exhausted; no silent 400/500-item truncation in `next`, `list`, `move`, or seeding.
- **§7.5 test flakes** — WHEN a server-lifecycle check fails in `run-tests.sh` THE SYSTEM SHALL retry it once and report the flake distinctly (closes issue #8); server-lifecycle sections SHALL use per-run randomized ports.
- **§7.6 brain.py** — WHEN a tag contains both an embedded double-quote and a comma THE SYSTEM SHALL round-trip it intact through `render_note` (escape on write, unescape on parse).

## §8 Self-improvement completion (E2)

- **§8.1 gate capture** — WHEN the gate exits non-zero THE SYSTEM SHALL append the failing command's tail output + timestamp to a local lessons feed (input to the next retro) before clearing the pass marker.
- **§8.2 retro enforcement** — WHEN a PR closes (merge or abandon) THE SYSTEM SHALL require the retro step in `build-next`; skipping SHALL require a stated reason in the iteration report.
- **§8.3 graduation** — WHEN a note's `strength` crosses the configured threshold THE SYSTEM SHALL surface it in `brain.py graduate-check` with a proposed destination (ROLE.md rule / invariant / test-or-lint); graduation itself stays a human-visible retro action.
- **§8.4 telemetry** — WHILE the loop runs THE SYSTEM SHALL append per-iteration records (task id, status transitions with timestamps, gate attempts, review rounds, estimate) to a local telemetry log; `board.sh metrics` SHALL report cycle time per status, first-try gate rate, rework (review-round) rate, and estimate-vs-actual calibration.
- **§8.5 loop feedback**
  - **§8.5.1 emission** — WHEN a build-loop iteration ends AND `methodology.feedback` is enabled THE SYSTEM SHALL collect structured feedback about the WORKFLOW (never the project being built) as a `loop-feedback` record — `schemaVersion`, `ts`, `iteration` (task, outcome, reviewRounds), `source` (role, model), and one or more `items[]` each carrying `category` (worked-well/friction/incident/recommendation), `area`, `severity`, `summary`, and a `generalized` restatement — and append it to the configured feed (`methodology.feedback.feed`, default `.claude/feedback/feed.yaml`).
  - **§8.5.2 generalization contract** — THE SYSTEM SHALL enforce, at emission time, that project specifics never leave the feed: an item's `generalized` field, when non-empty, together with its `summary`, SHALL NOT contain the iteration's own task id or a `#<digits>` issue/PR reference; such a record SHALL be rejected with an actionable error rather than appended. An item whose `generalized` field is empty SHALL be treated as local-only and SHALL be routable only as `ignore`.
  - **§8.5.3 triage** — WHEN a retro runs THE SYSTEM SHALL triage every unrouted feedback item (no `routing.action` set): dedupe its `generalized` text against existing backlog issues, then assign exactly one routing action — `backlog` (a new board issue is created from the generalized text only, marked `from-feedback`), `brain-note` (folded into the existing retro brain-minting protocol — never a second minting path), `graduate`, `upstream` (surfaced to a human once), or `ignore` (with a stated reason) — and record that action back onto the item.
  - **§8.5.4 explicit consent for backlog routing** — `methodology.feedback.autoTriage` SHALL default to `false`; WHILE it is false, routing an item to `backlog` SHALL require explicit human consent before the board issue is created, mirroring `methodology.autoMerge`'s consent model. WHEN `autoTriage` is `true`, backlog routing MAY proceed without a per-item check-in.

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

## §10 Non-functional

- The hermetic suite completes in under ~2 minutes on a dev laptop.
- All merge-gating tests are deterministic: no wall-clock dependence, no model calls, no network beyond the fake-gh harness.

## §11 Testing strategy

Merge gate = `tests/run-tests.sh` + `shellcheck -x` over all shell + `claude plugin validate` (manifests). Model evals (`claude plugin eval`) are advisory: run on demand, never merge-gating (cost + non-determinism).

## §12 Open questions

| id | question | owner | default if unanswered |
|---|---|---|---|
| OQ-1 | Inbound tasks: dedicated Status vs a label? | user (being decided in the find-task design session) | label `inbound`, Status stays Backlog |
| OQ-2 | New `board.sh add` verb vs generalizing `bug`? | user (same session) | generalize `bug` → `add` with a type flag |
| OQ-3 | One capture skill or two (`/find-task` + `/create-inbound`)? | user (same session) | two skills |
| OQ-4 | Medium-confidence duplicate behavior? | user (same session) | ask the human |
| OQ-5 | Telemetry storage? | orchestrator | `.claude/telemetry.jsonl`, gitignored |
