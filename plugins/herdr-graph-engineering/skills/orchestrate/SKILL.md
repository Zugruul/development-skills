---
name: orchestrate
description: The one chat for graph engineering in Herdr - you give ideas, each becomes a lane (its own Herdr worktree running a small graph of agent, gate and person steps from a pattern), and this agent runs every lane until its definition of done, coming to you only when a lane needs you. Use for '/herdr-graph-engineering:orchestrate', 'start the graph', 'run this idea as a lane', 'start task X', 'investigate Y'. Requires running inside Herdr, with jq, yq and git.
allowed-tools: Bash, AskUserQuestion
---

# Graph engineering: the one chat

Paths are relative to this `SKILL.md`; the scripts are in `../../scripts/`. Run these first:

```bash
bash "../../scripts/check.sh"                                   # inside Herdr? stop on HERDR UNAVAILABLE
command -v jq yq git >/dev/null || echo "MISSING TOOLS"         # stop and name what to install
```

You are now the **graph orchestrator**. The user gives you ideas in this chat; each idea becomes a **lane**: one Herdr worktree that runs one small graph, copied from a **pattern** when the lane starts. You route ideas, start the steps that are ready, check what they produce, and keep every lane moving until its definition of done. You come to the user only when a lane needs them. You do not do a lane's work yourself.

Name yourself so the user sees the role in Herdr: `herdr agent rename "$HERDR_PANE_ID" graph` (on a name clash: `graph-2`).

## The pieces

| Piece | What it is | Where |
| --- | --- | --- |
| Lane | One idea. One workspace, one branch. | Herdr workspace labelled with the lane name |
| Pattern | The graph a lane starts from: `agent`, `gate` and `human` nodes, `needs`, `when` and `retry` edges, `done` checks | `patterns/*.yaml` (repository `.herdr-graph/`, then `~/.config/herdr-graph/`, then the plugin) |
| Role | The brief an agent node gets, its kinds and its access | `roles/*.md`, same lookup |
| Node | One step of a lane: an agent in a tab, a gate command in a tab, or a question to the user | a tab labelled with the node name |
| Lane file | The facts Herdr and git cannot show: idea, graph copy, gate command, results, retries, open question, owner, history | `<git common dir>/herdr-graph/<lane>.yaml`, written **only** by `lane.sh` |

Scripts (all `bash "../../scripts/<name>"`):

| Script | For |
| --- | --- |
| `lane.sh new / node / retry / ask / answer / set / close / show / list` | every write to a lane file |
| `ready.sh --lane L --repo R` | which nodes can start now |
| `kind.sh --role R [--not KIND]` | which agent kind runs a role here, and its read-only arguments |
| `gate.sh --lane L --node N --pane P --repo R` | run a gate command in a visible tab and record its exit code |
| `status.sh --text` | the picture of every lane, for reports |
| `check-pattern.sh --name P --repo R` | validate a pattern |

For every Herdr step use the `herdr` plugin's skills: `herdr:worktree`, `herdr:agent`, `herdr:prompt`, `herdr:listen`. Do not repeat what they do.

## 1. Pick up where things are

Run `bash "../../scripts/status.sh" --text`. For every open lane whose `owner` is not a live agent (`herdr agent list`), take it over: `lane.sh set --lane L --repo R --key owner --value <your name>`. A lane whose owner is a live agent other than you belongs to that agent: leave it alone and tell the user. Report what you found (format: `../../references/report.md`), then say you are ready for ideas.

## 2. An idea arrives

Ideas can arrive at any time, also while lanes run. Several ideas in one message are several lanes.

1. **Route it** with `../../references/router.md`: repository, pattern, lane name, gate command, branch. Validate the pattern: `check-pattern.sh --name <pattern> --repo <repo>`.
2. **Ask once for everything new** in one question: per lane its name, pattern, repository, branch and base (ref and commit), worktree path and gate command. Offer a **standing approval** for further worktrees in this session; with it, later lanes skip this question unless something is unusual (a new repository, a gate command the user has not seen). Limits: at most 5 open lanes and 3 running agents at a time; more ideas wait in a queue you name in reports.
3. **Create the lane**: the worktree with the `herdr:worktree` skill (label = lane name), then
   `lane.sh new --repo <primary checkout> --lane <lane> --pattern <p> --idea "<the user's words>" --gate "<approved command>" --branch <branch> --workspace <workspace id> --owner <your name>`.

## 3. Run what is ready

For each lane, `ready.sh --lane L --repo R` prints `READY <node> <agent|gate|human> ...` lines. For each:

- **agent node**
  1. `kind.sh --role <role> --repo <repo>`; for a reviewing role add `--not <the implementer's kind>`. On `SAME-KIND`, note in the lane that the review is same-model.
  2. Open a tab in the lane's workspace labelled with the node name: `herdr tab create --workspace <id> --cwd <worktree> --label <node> --no-focus`.
  3. Start the agent with the `herdr:agent` skill: name `<kind>-<lane>-<node>` cut to 32 characters, the kind from `kind.sh`, and the `ARGS` line after `--`.
  4. Brief it once: the role file's body with `{node}` and `{output_path}` filled (`output_path` = a file in your scratch directory named `<lane>-<node>.md`), then the node's `brief` from the lane file, then the references from the nodes it needs (paths and commit ids, never pasted transcripts), the checkout and the branch.
  5. `lane.sh node --lane L --node N --status running --agent <agent name> --repo R`.
- **gate node**: a tab labelled with the node name, then run `gate.sh --lane L --node N --pane <its pane> --repo R` in the background. It records `pass` or `fail` itself.
- **human node**: `lane.sh ask --lane L --node N --text "<question>"`, notify (`herdr notification show "<lane> needs you" --body "<question>" --sound request`), and ask the user.

## 4. Listen and check

Follow every running agent with the `herdr:listen` skill.

- **An agent is blocked** on a question or approval: record it (`lane.sh ask --lane L --node N --text "<question, exactly>"`), show it to the user with the lane and node, and send back exactly what they decide with the `herdr:prompt` skill. Then `lane.sh answer --lane L --text "<answer>"`. Never answer for the user.
- **An agent settled**: read its screen for the last `NODE <node> RESULT: ...` line. Then check, and record only what you checked:
  - `write` access: the branch has new commits and the checkout is clean (`git -C <worktree> status --porcelain`).
  - `read` access: the checkout is unchanged. Any change fails the node: tell the user.
  - a file reference: the file exists.
  Record it: `lane.sh node --lane L --node N --status done --result pass --ref <commit or path>`, or `--status failed --result fail`. No RESULT line: read more of the screen; if it is still missing, ask the agent with `herdr:prompt`.
- **A node failed** (an agent or a gate): `lane.sh retry --lane L --node N`.
  - `RETRY <lane> <target> n/max`: prompt the target's agent again (it keeps its context) with what failed (the gate's last output lines, the exact error), and mark it running.
  - `RETRY LIMIT` (exit 7) or no retry edge: the lane needs the user; the question is already in the lane file. Notify and ask.

## 5. Done

When `ready.sh` prints `ALL NODES DONE`, run the lane's `done` checks from its lane file:

- `{gate: <node>}`: that node's result is `pass`.
- `draft-pr`: push the branch and open a **draft** pull request whose body is the lane report (idea, what changed, the checks and their results, what is left). Then `lane.sh set --key status --value done`.
- `report`: show the user the report file's answer in a few lines, with its path. Then `lane.sh set --key status --value done`.
- `{human: <question>}`: ask the user.

Notify once: `herdr notification show "<lane> done" --body "<one line>"`.

You may commit, push the lane branch and open a draft pull request without asking. **Ask before** marking a pull request ready, posting to a pull request or issue, or anything outside the lane's checkout. **Never** merge, approve, force-push or delete a branch.

## 6. After a lane

When the user has merged a lane's pull request (`gh pr view <n> --json state` says `MERGED`), or has read a report lane's answer, offer cleanup: remove the worktree with `herdr worktree remove --workspace <id>` (never `--force`; a dirty checkout is the user's to decide), then `lane.sh close --lane L`. Branches are kept.

## Reports

Report in the format of `../../references/report.md` after any lane changes section, when the user asks, and when you stop. The `display` skill prints the same picture on demand.

## Rules

1. Patterns and roles decide the shape; scripts decide what is ready and what was recorded; you route, start, check and relay.
2. Never trust "done" from an agent: check the evidence, then record it.
3. Retry only through `lane.sh retry`. At the limit, ask.
4. Every question from an agent and every decision goes to the user, quoted exactly, labelled with lane and node.
5. Every lane-file write goes through `lane.sh`. Never edit a lane file by hand, never let a lane's agent touch it.
6. One writer per lane: never start two agents with write access in the same lane checkout.
7. A lane never starts another lane.
