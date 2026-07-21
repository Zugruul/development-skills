---
name: implement-task
description: Implements ONE board task — design-doc guard, brief a dev subagent (what/how/why, strict TDD), verify tests-first + invariants + spec deltas, two-pass review (spec compliance then code quality), drive the board. Use when a specific issue #N is picked and ready to build.
allowed-tools: Bash
---

# Implement one task — orchestrate a dev agent

Pre-start check — run this now, before anything else: `bash "../../scripts/preflight.sh" --spec`. If it prints `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

You (the orchestrator) do **not** write the implementation. You brief a subagent, verify its result, and keep the board honest. Read `.claude/project.yaml` first — it supplies every `<cfg:...>` value below. `board.sh` = `bash "../../scripts/board.sh"`.

## 0. Prep
1. `board.sh show N` — read body **and all comments** (human steering lives there). If comments change scope: fold them into the body via `board.sh edit-body`, then acknowledge via `board.sh comment` (see `next-task`).
2. Read the task's acceptance criteria in `<cfg:specs[].backlogPath>` and the referenced sections of `<cfg:specs[].specPath>`. **Stale-criteria check**: criteria are written at seed time and the spec moves on — any criterion that contradicts the CURRENT spec/design doc (renamed concepts, dropped features, superseded contracts) gets flagged on the issue (`board.sh comment`) and resolved (spec wins) BEFORE the brief; implementing a stale criterion is a wasted PR.
3. **Design-doc guard**: the task's epic must have `<cfg:paths.designDir|docs/design>/<spec-id>-<epic-id>.md`. Missing → YOU write it now from the spec §s (format: `../../skills/implement-task/references/design-and-deltas.md` §1) and commit it before briefing anyone. Existing → read it; it constrains the brief.
4. Branch + board (same step, real time):
   ```bash
   git switch -c <branch from cfg:project.branchPattern, e.g. cp/012-error-model>
   board.sh move N "In progress"        # respect cfg:methodology.maxInProgress
   ```

## 1. Spawn the dev agent
Resolve the dev identity for THIS task's paths first: `bash "../../scripts/identity.sh" dev <a representative changed/expected path>`. In a monorepo the `covers` globs route to the right per-package dev agent; with a single dev identity it just returns that one. The resolved `models:` line is that agent's ALLOWED set — pick the most SUITABLE one for this task (cheaper/smaller for a simple change, a larger-context `[1m]` variant for a big diff), never reflexively the most powerful. Under Codex, resolve with `identity.sh --host codex dev <path>` and pick the model from its `codex-capability:` line (or the host's own default if it reads `(unset — host default)`) — never a Claude-only model id. Under Claude Code, resolve normally (no `--host` flag) and pick from `models:`, as today. Delegate to a fresh implementation agent when the host supports delegation, with `model: <the id you chose from that allowed set>` and `name: dev-<task-id>` (role-prefix FIRST, then the scope it serves — e.g. `dev-cp012`; a re-brief on the same task appends a letter, `dev-cp012-b`; never a bare counter — see build-next `references/concurrency.md` §Naming). (On Claude Code, this is the Agent tool with `subagent_type: general-purpose`.) One agent = one task. Fill EVERY section of the brief — specific WHAT/WHY beats generic. The subagent sees ONLY the brief: paste actual text (criteria, spec excerpts, invariants, error output), never write "as discussed" or "see above".

If per-identity brains exist (`.claude/identities/`), prepend the dev role's `ROLE.md` and a `## LESSONS (recalled)` block from `brain.sh recall dev` to the brief — protocol in `../../skills/build-next/references/brains.md`.

```
You are a senior engineer implementing ONE task of <cfg:project.name> (<cfg:project.description>).
Work strictly TDD. Do NOT touch the project board (the orchestrator owns it).
Branch already checked out: <branch>.

## WHAT
- Task: <id>: <title> (GitHub issue #N)
- Acceptance criteria: <paste from issue body + backlog row, including comment-driven updates>
- In scope: <exact deliverables>. Out of scope: <what NOT to build — later tasks>.
- Relevant spec sections: <spec path + section numbers, one line each>.

## HOW (non-negotiable)
1. TDD: write FAILING tests first, commit them ("test(<id>): ... (red)"), then minimal
   implementation, then refactor. No production code without a failing test.
2. Project invariants (hard rules): <paste cfg:specs[].invariants verbatim>.
   Architecture: follow the epic design doc at <paths.designDir>/<spec-epic>.md —
   <paste its Components/Interfaces/Decisions sections>. If your implementation would
   contradict it, STOP and report; do not silently diverge.
   Contract changes: if you change/extend/correct ANY spec contract, write the delta
   file <paths.specDeltaDir>/<task-id>.md (format pasted below from the orchestrator's
   reference §2) and commit it on this branch. Never edit the spec directly.
3. Tests: unit + integration where a real boundary is crossed. Deterministic time/ids in
   tested paths. <if cfg:methodology.isolationSuite: "Changes touching protected resources
   must add cases under <isolationSuite>.">
4. Run `<cfg:commands.gate>` until GREEN. Then push the branch and open a PR with body
   "Closes #N". Report the PR URL.
5. Match surrounding code style; small focused commits; update spec/docs if you changed a contract.
   Documentation you own in this change: <paste the cfg:docs[] sets whose `covers` globs match
   the task's expected paths — id, path, notes>. If your diff changes behavior/config/usage a
   set documents, update it in the same PR; if none needed, say why in the PR body.
6. Author every commit with these exact flags (per-commit -c flags only — never git config writes):
   git <paste the `flags:` line from `bash "../../scripts/identity.sh" dev <this task's path>` — same covers-selected identity as the spawn> commit ...
   <omit this section if identity.sh reports the dev role OFF or UNRESOLVED>

## WHY
<the architectural reason this task exists + the invariant it protects — derive from the spec;
be concrete so the agent makes good judgment calls>

## DELIVERABLE
Report: files changed, failing-test-first evidence, gate result, PR URL.
If the gate cannot go green, STOP and report the exact blocker — do not fake it.
```

Large task? Split into sequential briefs (e.g. tests+core, then edge cases), each still TDD.

## 2. Verify (trust but verify)
- Re-run `<cfg:commands.gate>` yourself.
- Check: red commit precedes implementation in `git log`; invariants respected; isolation cases present if applicable; design doc followed; a spec delta exists **iff** the diff changed a contract (missing delta on a contract change = send the agent back); docs updated.
- Red gate or blocker → keep *In progress*; re-brief the agent with the specific fix, or escalate (human blocker → `handoff` + `board.sh comment N` explaining what's needed).
- Prefer letting the dev agent commit its own fix (author == committer). When YOU must record a fix the dev agent (or reviewer findings) produced, commit **on behalf**: `identity.sh on-behalf dev --co reviewer` prints a `flags:` line (committer `-c` options, go before `commit`), a `commit-flags:` line (`--author=`, goes after `commit`), and Co-authored-by trailers so the record credits every participating role — never commit another role's work under a bare `identity.sh orchestrator` (auto-review.md §Commit identities, rules a–e).

## 3. Review + board
```bash
board.sh move N "In review"     # a hook blocks this unless gate.sh recorded a pass for the current tree
```
Review in **two passes**, each by a review agent (`model:` a suitable id from the reviewer identity's allowed set — `bash "../../scripts/identity.sh" reviewer` prints its `models:` line): (1) **spec compliance** — does the diff satisfy each acceptance criterion and cited spec §, nothing more, nothing less; (2) **code quality** — correctness, style, tests. Relay findings to a dev agent; re-gate. A single combined pass reliably misses "passes tests but isn't what the spec said."

If per-identity brains exist, prepend the reviewer role's `ROLE.md` and a `## LESSONS (recalled)` block from `brain.sh recall reviewer --paths "<the diff's paths>" --keywords "<task keywords>"` to EACH review-pass brief — same protocol as the dev brief (brains.md mandates recall for dev AND reviewer briefs; a reviewer brain that is minted at retro but never recalled never fires its links and its lessons never reach a review).

The orchestrator's OWN artifacts (design docs it wrote, release notes) use the `flags:` line from `identity.sh orchestrator` the same per-commit way (skip if OFF/UNRESOLVED). Recording work another role produced (a folded spec delta the dev agent wrote, a relayed fix) uses `identity.sh on-behalf <that role>` instead so the author stays truthful — see auto-review.md §Commit identities.

work.type governs delivery (absent == `pr`): `pr` — push the branch, `gh pr create` (body "Closes #N"), review the PR, `gh pr merge` (current text above stands). `local` — the branch stays local; review is `git diff <cfg:project.mainBranch>..<branch>` instead of a PR diff; approval recorded as an ISSUE comment (not a PR review); the orchestrator squash-merges locally with role attribution (same Applied-by/Reviewed-by/Co-authored-by recipe as the PR path — `auto-review.md` §Commit identities) and pushes `<cfg:project.mainBranch>` (skip the push if the repo has no remote, and say so in the report); board announce carries the merge SHA, not a PR link. `autoMerge: false` + `work.type: local` → leave the branch unmerged at *In review* for the human (mirrors today's human-approves-a-PR path, just without the PR). Full protocol: `auto-review.md` §5 (LOCAL-ROUTE).

**Auto-merge** (`methodology.autoMerge: true`): after both passes are clean, do NOT wait for a human — run the PR-review/approve/merge protocol in `../../skills/build-next/references/auto-review.md` (independent reviewer agent on a suitable model from the reviewer identity's allowed list, ≤3 fix rounds, approval recorded on the PR, `gh pr merge`, merge announced on the issue + to live teammates).

## 4. Retro + feedback — MANDATORY at PR close, standalone or via `build-next`
This step applies every time this skill closes a task (merge OR abandon), including a direct, standalone invocation of this skill. Do not assume a wrapping `build-next` loop will run it for you — if nothing else ran it this session, you own it.

**Telemetry**: after each review round in step 3, `telemetry.py <root> record '{"kind":"review-round","task":"N","round":R,"verdict":"...","ts":"<now, UTC ISO 8601>"}'` — for THIS skill's own two-pass review (§3), include `"pass":"spec-compliance"` or `"pass":"code-quality"` matching which of the two passes the round belongs to (#236, CDX-031 gap #4: `two-pass-review-preflight.sh` reads this back before the move to *QA*; auto-merge's separate reviewer-approval dialogue in `auto-review.md` stays as-is, no `pass` field); once the task closes (merge/QA), `telemetry.py <root> record '{"kind":"task-close","task":"N","estimate":<points>,"ts":"<now>"}'` (estimate from `board.sh show N` / the issue).

**Retro**: interview the dev and reviewer agents, mint/prune/graduate brain notes, regenerate the directory, commit as the orchestrator — full protocol, including `.claude/lessons.jsonl` (SW-020) as retro input, in `../../skills/build-next/references/brains.md`. If the brief(s) injected recalled notes, record an outcome for each pasted slug before minting — `brain.sh outcome <role> <slug> useful|dead_end|corrected [--task <ref>] [--note "<what was wrong>"]`, `--note` required for `corrected` — same protocol, `../../skills/build-next/references/brains.md` §"Closing the loop". `.claude/identities/` not existing yet is NOT a skip reason — minting is self-bootstrapping (`brain.py mint` creates the directory); treat a missing dir the same as an empty one and mint into it. The only valid skips are `delegation.identities` being absent/fully disabled for this repo, or a genuine blocker (e.g. no orchestrator identity configured to author the commit) — either way, state it via `retro: SKIPPED — <reason>` in your final report, AND `telemetry.py <root> record '{"kind":"retro-skip","reason":"...","ts":"<now>"}'` — a silent skip is never acceptable.

**Feedback** (if `methodology.feedback` enabled, distinct from and in addition to retro — feedback emits/triages a per-task process signal, retro mints brain notes; neither replaces the other): invoke the `feedback` skill to record this task's process signal. Then, as the ORCHESTRATOR — never a dev agent — triage `feedback.py <root> pending`: dedupe each item's `generalized` text via `python3 scripts/similar.py <root> "<generalized text>"` against existing issues, then `feedback.py <root> route <ts> <idx> <action> <ref>` per item — `backlog`, `brain-note` (folds into this step's minting — never a second minting path), `graduate`, `upstream`, or `ignore` (state why). `methodology.feedback.autoTriage` (default false) gates `backlog` routing on explicit human consent. Once every pending item is routed, run `feedback.py <root> archive` as the final action of this step and commit the routed feed + archives together as the orchestrator identity.

If the task involves UI-affecting decisions and iterative UI mode is on (`.claude/ITERATIVE_UI_OFF` absent, `methodology.iterativeUI` not false): follow the `ui-options` skill's protocol (see `build-next` skill, "Iterative UI mode") rather than guessing — this applies whether or not a `build-next` loop is wrapping this invocation.

## 5. Stop
One task per invocation. Report: task, gate result, PR link, board status, and a **retro-status line** (`retro: done (notes minted/pruned: ...)` or `retro: SKIPPED — <reason>`) per step 4. Later statuses (QA/Ready/Deployed) only when merge/validation/publish actually happen.
