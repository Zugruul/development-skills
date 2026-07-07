---
name: implement-task
description: Implements ONE board task — design-doc guard, brief a dev subagent (what/how/why, strict TDD), verify tests-first + invariants + spec deltas, two-pass review (spec compliance then code quality), drive the board. Use when a specific issue #N is picked and ready to build.
allowed-tools: Bash
---

# Implement one task — orchestrate a dev agent

Pre-start check: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --spec`
If the line above says `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

You (the orchestrator) do **not** write the implementation. You brief a subagent, verify its result, and keep the board honest. Read `.claude/project.yaml` first — it supplies every `<cfg:...>` value below. `board.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh"`.

## 0. Prep
1. `board.sh show N` — read body **and all comments** (human steering lives there). If comments change scope: fold them into the body via `board.sh edit-body`, then acknowledge via `board.sh comment` (see `next-task`).
2. Read the task's acceptance criteria in `<cfg:specs[].backlogPath>` and the referenced sections of `<cfg:specs[].specPath>`. **Stale-criteria check**: criteria are written at seed time and the spec moves on — any criterion that contradicts the CURRENT spec/design doc (renamed concepts, dropped features, superseded contracts) gets flagged on the issue (`board.sh comment`) and resolved (spec wins) BEFORE the brief; implementing a stale criterion is a wasted PR.
3. **Design-doc guard**: the task's epic must have `<cfg:paths.designDir|docs/design>/<spec-id>-<epic-id>.md`. Missing → YOU write it now from the spec §s (format: `${CLAUDE_PLUGIN_ROOT}/skills/implement-task/references/design-and-deltas.md` §1) and commit it before briefing anyone. Existing → read it; it constrains the brief.
4. Branch + board (same step, real time):
   ```bash
   git switch -c <branch from cfg:project.branchPattern, e.g. cp/012-error-model>
   board.sh move N "In progress"        # respect cfg:methodology.maxInProgress
   ```

## 1. Spawn the dev agent
Resolve the dev identity for THIS task's paths first: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh" dev <a representative changed/expected path>`. In a monorepo the `covers` globs route to the right per-package dev agent; with a single dev identity it just returns that one. The resolved `models:` line is that agent's ALLOWED set — pick the most SUITABLE one for this task (cheaper/smaller for a simple change, a larger-context `[1m]` variant for a big diff), never reflexively the most powerful. Spawn with the Agent tool, `subagent_type: general-purpose`, `model: <the id you chose from that allowed set>`, and a descriptive `name`. One agent = one task. Fill EVERY section of the brief — specific WHAT/WHY beats generic. The subagent sees ONLY the brief: paste actual text (criteria, spec excerpts, invariants, error output), never write "as discussed" or "see above".

If per-identity brains exist (`.claude/identities/`), prepend the dev role's `ROLE.md` and a `## LESSONS (recalled)` block from `brain.sh recall dev` to the brief — protocol in `${CLAUDE_PLUGIN_ROOT}/skills/build-next/references/brains.md`.

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
   git <paste the `flags:` line from `bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh" dev <this task's path>` — same covers-selected identity as the spawn> commit ...
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
- Prefer letting the dev agent commit its own fix (author == committer). When YOU must record a fix the dev agent (or reviewer findings) produced, commit **on behalf**: `identity.sh on-behalf dev --co reviewer` prints the committer `-c` flags + `--author=` + Co-authored-by trailers so the record credits every participating role — never commit another role's work under a bare `identity.sh orchestrator` (auto-review.md §Commit identities, rules a–e).

## 3. Review + board
```bash
board.sh move N "In review"     # a hook blocks this unless gate.sh recorded a pass for the current tree
```
Review in **two passes**, each by a review agent (`model:` a suitable id from the reviewer identity's allowed set — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh" reviewer` prints its `models:` line): (1) **spec compliance** — does the diff satisfy each acceptance criterion and cited spec §, nothing more, nothing less; (2) **code quality** — correctness, style, tests. Relay findings to a dev agent; re-gate. A single combined pass reliably misses "passes tests but isn't what the spec said."

The orchestrator's OWN artifacts (design docs it wrote, release notes) use the `flags:` line from `identity.sh orchestrator` the same per-commit way (skip if OFF/UNRESOLVED). Recording work another role produced (a folded spec delta the dev agent wrote, a relayed fix) uses `identity.sh on-behalf <that role>` instead so the author stays truthful — see auto-review.md §Commit identities.

**Auto-merge** (`methodology.autoMerge: true`): after both passes are clean, do NOT wait for a human — run the PR-review/approve/merge protocol in `${CLAUDE_PLUGIN_ROOT}/skills/build-next/references/auto-review.md` (independent reviewer agent on a suitable model from the reviewer identity's allowed list, ≤3 fix rounds, approval recorded on the PR, `gh pr merge`, merge announced on the issue + to live teammates).

## 4. Stop
One task per invocation. Report: task, gate result, PR link, board status. Later statuses (QA/Ready/Deployed) only when merge/validation/publish actually happen.
