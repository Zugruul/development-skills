---
name: retrospective
description: Runs the orchestrator's retro protocol on demand — dedupe/route any pending feedback and mint/prune/graduate brain notes from it — independent of a build-next PR-close. Use when the human explicitly asks to run a retrospective or "update the brains from feedback", or when the feedback skill offers this at the end of a standalone session and the human accepts.
allowed-tools: Bash
---

# /retrospective — on-demand brain-note retro

`build-next` step 7 already runs this protocol automatically at every PR close. This
skill exists for everything that isn't that moment: a standalone `/feedback` session
with no PR to close, a manual catch-up after a gap, or recovering a repo whose loop
never reached a natural retro at all. Same underlying protocol either way — this
skill is just the entry point when nothing else is going to trigger it.

## When to run
- The human explicitly asks for a "retrospective" / "retro" / "update the brains
  (neural network) from feedback".
- The `feedback` skill's standalone-invocation step offers this and the human accepts.
- Recovering a stalled repo — `telemetry.py <root> metrics` shows `retro skips`, or
  many `task-close`/`transition` events with no matching `.claude/identities/`
  activity in git history (a brain that never got its first note).

## Protocol
1. **Gather input.**
   - `feedback.py <root> pending` — every unrouted feedback item, not just from one iteration.
   - `.claude/lessons.jsonl` (gate-failure signatures, SW-020) — a recurring failure
     signature there is retro input alongside/instead of feedback items.
   - If dev/reviewer subagents are still live in this session (a same-session
     `/feedback` → `/retrospective` chain right after their work), interview them per
     `build-next/references/brains.md` step 1. If not — a cold/manual invocation —
     skip the interview and work from the recorded feedback/lessons text alone, and
     say so in the report; don't fabricate a interview that didn't happen.
2. **Triage.** For each pending item: dedupe via `similar.py` against the board, then
   `feedback.py route <ts> <idx> <action> <ref>` — `backlog` / `brain-note` /
   `graduate` / `upstream` / `ignore`, per `build-next/SKILL.md` step 8's category
   meanings. An item whose `ref` would duplicate an already-tracked issue routes
   `upstream`/`ignore` with that issue cited, not a fresh `backlog` filing.
3. **Mint.** For every item routed `brain-note` (this run's, or a prior run's that
   was routed but never minted): `brain.sh mint <role> <slug> --tags ... --paths ...
   --source "..."` — one idea per note, **in your own wording** (never paste the
   feedback item's text verbatim), wikilinking related slugs within the same role's
   brain only (cross-role `[[slug]]` links don't resolve — each role's links.json is
   its own file). Re-minting an existing slug just bumps its strength.
4. **Prune + graduate.** `brain.sh status <role>` first — the per-note `✓/✗/⚠` outcome
   tally flags notes worth pruning or re-minting before you even open `prune`, and a
   note with repeated `✗` and no `✓` will surface in `brain.sh prune <role>`'s output
   too (SPEC-GRAPHIFY §7 R7.6). `brain.sh prune <role>` (review flagged links; `--apply`
   to remove); `brain.sh graduate <role> <slug>` for any lesson proven durable enough to
   become an invariant/`ROLE.md` rule instead of a standing note; `brain.sh retro-mark`
   bumps the retro counter that ages notes for pruning.
5. **Directory.** `brain.sh directory` to regenerate `DIRECTORY.md`.
6. **Archive.** `feedback.py <root> archive` — moves every fully-routed feed document
   into `.claude/feedbacks/archive/<YYYY-MM>.yaml`, as the LAST feed action of this
   protocol, after routing (step 2) and mint/prune/retro-mark (steps 3-4).
7. **Commit** the routed feed, archives, and any brain changes together, as the
   orchestrator identity (`identity.sh orchestrator` for the `-c user.name=... -c
   user.email=...` flags — never a persistent `git config` write, see the note below).
8. **Report**: items triaged (counts by action), notes minted/pruned/graduated,
   `brain.sh retro-mark` bumped, and whether an interview happened or this ran from
   recorded text alone.

## A missing `.claude/identities/` dir is never a reason to stop
Minting is self-bootstrapping (`brain.sh mint` creates the directory). If this is a
repo's first-ever retro/retrospective, the directory not existing yet is the normal,
expected state — mint into it like any other run.

## Commit identity — never a persistent `git config` write
Always author the commit with `identity.sh orchestrator`'s one-off `-c user.name=...
-c user.email=...` flags on the commit command itself. Never run a bare `git config
user.name/user.email` (without `-c`, without `--global`) — that persists the value
into the repo's local config and silently corrupts every future commit's default
identity until someone notices and unsets it.

## Non-goals
- Does not create backlog issues beyond what triage routing calls for — a `backlog`
  routing still needs human consent unless `methodology.feedback.autoTriage` is set,
  same as `build-next` step 8.
- Does not touch code, tests, or board task status — purely the feedback→brain
  pipeline.
