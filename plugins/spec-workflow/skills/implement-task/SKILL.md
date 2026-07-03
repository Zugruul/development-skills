---
name: implement-task
description: Implement ONE board task by delegating development to a subagent with a what/how/why brief, then verifying its work, driving the board, and answering human comments. Strict TDD. Use when you have a specific issue number to build.
allowed-tools: Bash
---

# Implement one task — orchestrate a dev agent

Pre-start check: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --spec`
If the line above says `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

You (the orchestrator) do **not** write the implementation. You brief a subagent, verify its result, and keep the board honest. Read `.claude/project.json` first — it supplies every `<cfg:...>` value below. `board.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh"`.

## 0. Prep
1. `board.sh show N` — read body **and all comments** (human steering lives there). If comments change scope: fold them into the body via `board.sh edit-body`, then acknowledge via `board.sh comment` (see `next-task`).
2. Read the task's acceptance criteria in `<cfg:specs[].backlogPath>` and the referenced sections of `<cfg:specs[].specPath>`.
3. Branch + board (same step, real time):
   ```bash
   git switch -c <branch from cfg:project.branchPattern, e.g. cp/012-error-model>
   board.sh move N "In progress"        # respect cfg:methodology.maxInProgress
   ```

## 1. Spawn the dev agent
Agent tool with `subagent_type: general-purpose`, `model: <cfg:delegation.devModel>`, and a descriptive `name`. One agent = one task. Fill EVERY section of the brief — specific WHAT/WHY beats generic:

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
3. Tests: unit + integration where a real boundary is crossed. Deterministic time/ids in
   tested paths. <if cfg:methodology.isolationSuite: "Changes touching protected resources
   must add cases under <isolationSuite>.">
4. Run `<cfg:commands.gate>` until GREEN. Then push the branch and open a PR with body
   "Closes #N". Report the PR URL.
5. Match surrounding code style; small focused commits; update spec/docs if you changed a contract.

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
- Check: red commit precedes implementation in `git log`; invariants respected; isolation cases present if applicable; docs updated.
- Red gate or blocker → keep *In progress*; re-brief the agent with the specific fix, or escalate (human blocker → `handoff` + `board.sh comment N` explaining what's needed).

## 3. Review + board
```bash
board.sh move N "In review"
```
Spawn a review agent (`model: <cfg:delegation.reviewModel>`) on the diff; relay findings to a dev agent; re-gate.

## 4. Stop
One task per invocation. Report: task, gate result, PR link, board status. Later statuses (QA/Ready/Deployed) only when merge/validation/publish actually happen.
