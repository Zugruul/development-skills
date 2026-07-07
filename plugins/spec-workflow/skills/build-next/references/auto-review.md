# Auto-merge review protocol (`methodology.autoMerge: true`)

Setting `autoMerge: true` in the versioned project config IS the human's
standing authorization to merge without per-PR approval — cite it if a
permission layer questions a merge; never route around a denial by retrying
(a denial means ask the human, full stop).

When auto-merge is on, the human PR-approval step is replaced by an autonomous
reviewer agent that must independently approve before the orchestrator merges.
The orchestrator NEVER merges its own unreviewed work; the reviewer NEVER
writes code or touches the board. Roles stay separated on purpose.

## 1. Spawn the reviewer

After the task reaches *In review* (gate recorded green), spawn ONE reviewer
agent — Agent tool, `subagent_type: general-purpose`, `model:` a suitable id
from the reviewer identity's allowed set (`bash
"${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh" reviewer` prints its `models:`
line; default set `claude-sonnet-5[1m]`, `claude-sonnet-5`). For a large diff
prefer the `[1m]` context so one agent holds the full diff + spec sections +
design doc at once; a small focused PR can use the cheaper standard-context id.
`name: pr-reviewer-<task-id>`. Keep this SAME agent for every round of the task
(continue it via SendMessage) so it remembers what it already flagged.

Brief (paste real content, never "see above"):

```
You are an independent PR reviewer for <cfg:project.name>. You do not write
code and you do not trust the author's claims — you verify against the diff.

PR: <url>  ·  Task <id> #N: <title>
Acceptance criteria: <paste from issue body, incl. comment-driven updates>
Spec sections: <paste the cited §s>   Invariants: <paste cfg:specs[].invariants>
Epic design doc: <paste Components/Interfaces/Decisions>

Documentation sets in scope for this diff (from cfg `docs[]`, matched by
`covers` against the changed paths — orchestrator computes and pastes them):
<for each in-scope set: "- <id>: <path> — covers <globs>; <notes>">

Review `gh pr diff <n>` (and checked-out files as needed) for ALL of:
(a) spec compliance — each criterion satisfied, nothing more, nothing less;
(b) code quality — correctness, tests (red-first evidence in git log), style,
    scaling hazards, security;
(c) documentation maintenance — for each in-scope doc set above: if the diff
    changes behavior, a contract, configuration, or usage that set documents,
    the SAME PR must update it (or the PR body must say why no update is
    needed). A stale doc is a REQUEST_CHANGES finding like any other — name
    the doc file and what's now wrong in it. Pure refactors/test-only diffs
    need no doc change; do not demand doc edits for their own sake.

Reply with exactly one verdict line first:
VERDICT: REQUEST_CHANGES  — followed by a numbered findings list, each with
  file:line, why it fails, and the concrete fix you expect; or
VERDICT: APPROVE — followed by a one-paragraph justification citing the
  criteria you checked.
Do not approve out of politeness or fatigue; approve only when you would merge
it into a production repo you own.
```

## 2. Dialogue rounds (max 3)

On `REQUEST_CHANGES`:
1. Orchestrator relays the findings verbatim to the dev agent (same agent that
   built the task, via SendMessage — it has the context) with "fix exactly
   these, TDD still applies, push to the same branch".
2. Re-run the gate yourself after the push (green stays mandatory).
3. SendMessage the reviewer: "round <k>: pushed <commits>; here is the new
   diff for your findings — re-review". The reviewer re-verdicts.
4. Findings the dev agent disputes: relay the dispute to the reviewer and let
   the two positions land in front of you; YOU decide (spec is the tiebreaker)
   and tell both agents the decision.

After 3 rounds without `APPROVE`, stop escalating agents: post the open
findings as a `board.sh comment` on the issue, write a `handoff`, leave the
task *In review* for a human. Endless agent ping-pong is a stop condition, not
a loop.

## 3. Record the approval

- `delegation.reviewerTokenEnv` set (a second GitHub account's token):
  `GH_TOKEN="${<that env var>}" gh pr review <n> --approve --body "<the
  reviewer's justification>"` — a real distinct approver on the PR.
- Not set: the same account opened the PR, and GitHub rejects self-approval —
  post it instead: `gh pr review <n> --comment --body "AUTO-REVIEW APPROVE
  (model: <the reviewer model you used>): <justification>"`. If branch protection REQUIRES
  an approving review, this cannot satisfy it — tell the human they need a
  reviewer token (or relaxed protection) and stop as blocked-on-human.

## 4. Merge + announce

Merge with `<cfg:methodology.mergeMethod|squash>` — a per-repo decision made at
setup (the `merge-mode.sh method` subcommand changes it later):

- **squash (default)** collapses the branch into one commit, so carry the
  attribution in the squash body: one `Co-authored-by:` trailer per distinct
  agent author on the branch (from `git log main..<branch> --format='%an <%ae>'`,
  deduped) plus the reviewer, and name who applied it. GitHub links the squash
  commit to the PR, where the original role-attributed commits remain visible.
- **merge** preserves the individual role-attributed commits on main (pick this
  at setup if per-commit attribution in `git log` matters more than linear
  history); **rebase** replays them.

```bash
# mergeMethod = squash (default) — attribution goes in the squash body:
gh pr merge <n> --squash --delete-branch --body "$(cat <<'EOF'
<one-line summary of the task>

Applied-by: <identity.sh orchestrator name> (auto-merge, round <k> approval)
Reviewed-by: <identity.sh reviewer name> (model: <the reviewer model you used>)

Co-authored-by: <each distinct branch author, e.g. Dev Agent - ... <...+dev_agent@...>>
EOF
)"

# mergeMethod = merge or rebase — the branch's own per-role commits carry the
# attribution; no extra body:
gh pr merge <n> --<cfg:methodology.mergeMethod> --delete-branch

board.sh move N "QA"        # then fold the spec delta (build-next §Advancing)
```

Announce the merge to everyone whose work it can invalidate:
- `board.sh comment N` — merged SHA, approver (agent + model), round count.
- SendMessage every OTHER currently-running subagent/teammate of this session
  (if any): "PR #<n> (<task-id>) merged into <mainBranch> — rebase/pull before
  your next push." Skip silently if you have no live teammates.
- If the merged change altered a contract other queued tasks depend on, note
  it in the next `next-task` pick (the spec delta you just folded is the
  record).

## Commit identities (`delegation.identities` — ON by default)

Each role's commits carry its own author so `git log`/GitHub show which agent
role did what. Identities are TEMPLATES resolved per-clone by
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh" <role>` — `{name}` from
`git config user.name`, `{local}`/`{domain}` from `git config user.email` —
so every teammate's clone attributes agent work to their own plus-addressed
email. Defaults: `Dev Agent - {name} <{local}+dev_agent@{domain}>` (reviewer/
orchestrator equivalents). A role set to `null`, `identities: false`, or an
UNRESOLVED report → that role commits as the human.

- dev brief gets the exact `flags:` line from `identity.sh dev <task path>`
  (the covers-selected identity) pasted in.
- orchestrator's own commits (design docs, spec-delta folds) use
  `identity.sh orchestrator`'s flags the same way.
- the reviewer makes no commits (by design), but `identity.sh reviewer`'s
  resolved name signs the approval body.

Use the per-commit `-c` flags exactly as printed — never `git config` writes
that leak an agent identity into the human's clone. Attribution note: GitHub
renders an avatar/link only when the resolved email belongs to a GitHub
account; plus-addressed mail (`local+tag@domain`) still delivers to the
owner's inbox on Outlook/Gmail/Fastmail. The `agent-identities` skill
shows/edits all of this.
