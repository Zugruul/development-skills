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
| Pattern | The graph a lane starts from: `agent`, `gate`, `human` and `pr` nodes, `needs`, `when` and `retry` edges, `done` checks | `patterns/*.yaml` (repository `.herdr-graph/`, then `~/.config/herdr-graph/`, then the plugin) |
| Role | The brief an agent node gets, its kinds and its access | `roles/*.md`, same lookup |
| Node | One step of a lane: an agent in a tab, a gate command in a tab, or a question to the user | a tab labelled with the node name |
| Lane file | The facts Herdr and git cannot show: idea, graph copy, gate command, results, retries, open question, owner, history | `<git common dir>/herdr-graph/<lane>.yaml`, written **only** by `lane.sh` |

Scripts (all `bash "../../scripts/<name>"`):

| Script | For |
| --- | --- |
| `lane.sh new / node / retry / ask / answer / set / close / clear / show / list` | every write to a lane file |
| `ready.sh --lane L --repo R` | which nodes can start now |
| `kind.sh --role R [--not KIND]` | which agent kind runs a role here, and its read-only arguments |
| `gate.sh --lane L --node N --pane P --repo R` | run a gate command in a visible tab and record its exit code |
| `status.sh --text` | the picture of every lane, for reports |
| `check-pattern.sh --name P --repo R` | validate a pattern |
| `make-review-stack.sh --pr URL --pr URL ... --out FILE` | the graph for reviewing related pull requests together |

For every Herdr step use the `herdr` plugin's skills: `herdr:worktree`, `herdr:agent`, `herdr:prompt`, `herdr:listen`. Do not repeat what they do.

## 1. Pick up where things are

**After a compaction (or a new session)**, before anything else: run `bash "../../scripts/resume.sh"`. It prints one block, `RESUME` to `END RESUME`: every open lane of every repository with lanes (nodes, agents live or gone, open question, pull requests, done checks and the extra ones, notes) with its `next:` action, then the queued lanes, standing answers, renames, notes and files of your session file. In Claude Code a hook puts the same block into the chat after a compaction; if you see a summary of earlier conversation and no block, run it yourself. Then:

1. Trust the block over your summary: the files are the record. Use the standing answers in it as given by the user.
2. re-start `herdr:listen` for every agent the block shows live (working, blocked, idle); an agent shown `gone` is not running: follow that lane's `next:`.
3. Take each lane's `next:` action, start queued lanes while fewer than 3 agents run, and do not send again a brief or follow-up that a lane note says was sent.
4. Then continue below (panel, owners, report).

At the start of every orchestrator session, record where it lives (session name `graph`, or your agent name when that is taken):
`bash "../../scripts/session.sh" set --key pane --value "$HERDR_PANE_ID"`, then `--key orchestrator --value <your name>` and `--key scratch --value <your scratch directory>` (add `--session <name>` to each when it is not `graph`). The hooks find the session by this pane. Keep the session and lane files current as section "Keep state outside the chat" says.

Check the graph panel: `herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id == "herdr-graph-engineering.graph") | .enabled'`. Not installed: offer once, with the command `herdr plugin install Zugruul/development-skills/plugins/herdr-graph-engineering`; run it only if the user says yes (it shows its own preview). Installed and enabled: open it with `herdr plugin action invoke herdr-graph-engineering.graph.toggle`, unless a panel is already open in this tab.

Run `bash "../../scripts/status.sh" --text`. For every open lane whose `owner` is not a live agent (`herdr agent list`), take it over: `lane.sh set --lane L --repo R --key owner --value <your name>`. A lane whose owner is a live agent other than you belongs to that agent: leave it alone and tell the user. Report what you found (format: `../../references/report.md`), then say you are ready for ideas.

## 2. An idea arrives

Ideas can arrive at any time, also while lanes run. Several ideas in one message are several lanes.

1. **Route it** with `../../references/router.md`: repository, pattern, lane name, gate command, branch. Validate the pattern: `check-pattern.sh --name <pattern> --repo <repo>`.
2. **Ask once for everything new** in one question: per lane its name, pattern, repository, branch and base (ref and commit), worktree path and gate command. Offer a **standing approval** for further worktrees in this session; with it, later lanes skip this question unless something is unusual (a new repository, a gate command the user has not seen). Limits: at most 5 open lanes and 3 running agents at a time; more ideas wait in a queue you name in reports.
3. **Create the lane**: the worktree with the `herdr:worktree` skill (label = lane name), then
   `lane.sh new --repo <primary checkout> --lane <lane> --pattern <p> --idea "<the user's words>" --gate "<approved command>" --branch <branch> --workspace <workspace id> --owner <your name>`.
   A review passes `--input pr=<url>`. A review stack or an approved custom graph passes `--pattern-file <file>` instead of `--pattern`.

## 3. Run what is ready

For each lane, `ready.sh --lane L --repo R` prints `READY <node> <agent|gate|human> ...` lines, and `SKIP <node> (...)` for a node whose `when` does not hold: record that with `lane.sh node --lane L --node N --status skipped` and run `ready.sh` again. For each ready node:

- **agent node**
  1. `kind.sh --role <role> --repo <repo>`; for a reviewing role add `--not <the implementer's kind>`. On `SAME-KIND`, note in the lane that the review is same-model.
  2. Open a tab in the lane's workspace labelled with the node name: `herdr tab create --workspace <id> --cwd <worktree> --label <node> --no-focus`.
  3. Start the agent with the `herdr:agent` skill: name `<kind>-<lane>-<node>` cut to 32 characters, the kind from `kind.sh`, and the `ARGS` line after `--`.
  4. Brief it once: the role file's body with `{node}` and `{output_path}` filled (`output_path` = a file in your scratch directory named `<lane>-<node>.md`), then the node's `brief` from the lane file, then the references from the nodes it needs (paths and commit ids, never pasted transcripts), the checkout and the branch.
     - `pr-reviewer`: also paste `../../references/review-brief.md` (the template filled in, the three steps, the proof standard, the shared-checkout rules, the draft and comment formats), and the repository's rule files by path.
     - `reviewer` (a second opinion): also give the base ref, so it reviews exactly the lane's change.
     - `planner`: also paste two shipped patterns as examples.
  5. `lane.sh node --lane L --node N --status running --agent <agent name> --repo R`.
- **gate node**: a tab labelled with the node name, then run `gate.sh --lane L --node N --pane <its pane> --repo R` in the background. It records `pass` or `fail` itself.
- **pr node** (`pr: draft`, used by `fast` to open the pull request before the gate): push the lane branch; if it has no open pull request, open a **draft** one whose body is the lane report so far (idea, what changed, "checks still running"); otherwise the node simply pushes to the pull request that is already open. Record `lane.sh node --lane L --node N --status done --result pass --ref <pull request url>`. A retry to the implementer runs it again, so each fix reaches the same pull request.
- **human node**: `lane.sh ask --lane L --node N --text "<question>"`, notify (`herdr notification show "<lane> needs you" --body "<question>" --sound request`), and ask the user with what they need to decide (for a review: the counts by severity, the findings' titles, the draft paths). Then `lane.sh answer --lane L --text "<answer>"` and record the node: yes is `--status done --result pass`, no is `--status done --result fail` (the nodes that need a yes are then skipped).

## 4. Listen and check

Follow every running agent with the `herdr:listen` skill.

- **An agent is blocked** on a question or approval: record it (`lane.sh ask --lane L --node N --text "<question, exactly>"`), show it to the user with the lane and node, and send back exactly what they decide with the `herdr:prompt` skill. Then `lane.sh answer --lane L --text "<answer>"`. Never answer for the user.
- **An agent settled**: read its screen for the last `NODE <node> RESULT: ...` line. Then check, and record only what you checked:
  - `write` access: the branch has new commits and the checkout is clean (`git -C <worktree> status --porcelain`).
  - `read` access, and the `poster` role: the checkout is unchanged. Any change fails the node: tell the user.
  - a file reference: the file exists.
  Record it: `lane.sh node --lane L --node N --status done --result pass --ref <commit or path>`, or `--status failed --result fail`. No RESULT line: read more of the screen; if it is still missing, ask the agent with `herdr:prompt`.
- **A node failed** (an agent or a gate), or a `reviewer` asked for `changes`: `lane.sh retry --lane L --node N`.
  - `RETRY <lane> <target> n/max`: prompt the target's agent again (it keeps its context) with what failed (the gate's last output lines, the exact error, or the reviewer's findings file), and mark it running.
  - `RETRY LIMIT` (exit 7) or no retry edge: the lane needs the user; the question is already in the lane file. Notify and ask.

## 5. Done

When `ready.sh` prints `ALL NODES DONE`, run the lane's `done` checks from its lane file:

- `{gate: <node>}`: that node's result is `pass`.
- `draft-pr`: push the branch and open a **draft** pull request whose body is the lane report (idea, what changed, the checks and their results, what is left). When a `pr` node already opened it, push and update its body instead of opening another. Then `lane.sh set --key status --value done`.
- `report`: show the user the report file's answer in a few lines, with its path. Then `lane.sh set --key status --value done`.
- `{human: <question>}`: ask the user.
- `posted-review`: section "Reviews" below passed for every pull request of the lane. Then `lane.sh set --key status --value done`.

Notify once: `herdr notification show "<lane> done" --body "<one line>"`.

You may commit, push the lane branch and open a draft pull request without asking. **Ask before** marking a pull request ready, posting to a pull request or issue, or anything outside the lane's checkout. **Never** merge, approve, force-push or delete a branch.

## Reviews (`review` and stack lanes)

The output keeps one shape: per pull request, the replies, then **one `COMMENT` review** holding every new inline finding, whose **body is the summary**. Never approve, request changes, merge, push or mark ready.

1. **Drafts.** Every `pr-reviewer` node writes a draft in the brief's format. A draft that looks wrong goes back to its agent as a question; you do not add findings of your own.
2. **Merge** (before the `approve` node), one posting file per pull request in your scratch directory: a finding goes on the pull request that should change; **a finding two reviewers found is posted once** (keep the stronger proof and the better fix prompt); unconfirmed items are not posted, they go to the summary's "Worth a look"; a finding against a merged pull request becomes a proposed follow-up in the lane report.
3. **Approve.** The `approve` node asks the user, with the counts by severity and the titles. If the pull request's head moved since the review, say so and ask whether to re-check first.
4. **Post.** Each `post` node's `poster` re-checks every item against the code, posts the replies, then one `COMMENT` review at the reviewed head commit with the placeholder body `Review summary to follow.`, and reports every URL. With no new findings it posts only the replies.
5. **Verify** through the API, read-only (`gh api repos/<owner>/<repo>/pulls/<n>/reviews` and `.../comments`, `gh pr view`): exactly the posting file's replies and one `COMMENT` review, no approval and no change request; the pull request's state and draft flag unchanged; the checkout clean.
6. **Summary.** Write it in the format of `../../references/review-summary.md` exactly (commit checked, who covered what, how verified, whether tests ran; the count line; the numbered table linking each inline comment; "Worth a look", "Checked and found correct", one "Prompt for AI Agents" block). Put it into the review's body: `jq -n --rawfile body <summary> '{body: $body}' > <body.json>` then `gh api -X PUT repos/<owner>/<repo>/pulls/<n>/reviews/<review id> --input <body.json>`. With no new findings, post one `COMMENT` review whose body is the summary instead. Then check the review's body equals the summary file and its state is still `COMMENTED`.
7. Report the verified links, the poster's deviations, the leads that were not real, and the proposed follow-ups.

## Custom graphs (`plan` lanes)

When the planner's lane is done, validate its file: `check-pattern.sh <file> --repo <repo>`. Fix nothing yourself: send problems back to the planner. Show the user the graph (each node with its role or command, its needs, its retry) and the gate commands; only after they approve, start the real lane with `lane.sh new --pattern-file <file>`.

## 6. After a lane

When the user has merged a lane's pull request (`gh pr view <n> --json state` says `MERGED`), or has read a report lane's answer, offer cleanup: remove the worktree with `herdr worktree remove --workspace <id>` (never `--force`; a dirty checkout is the user's to decide), then `lane.sh close --lane L`. Branches are kept. The graph panel's `[x]` on a DONE lane sends you "Clean up lane L": treat it as the user asking for this cleanup, and still confirm before removing the worktree. `lane.sh clear --lane L` only moves a closed lane's file to `closed/cleared/` (the panel's `[x]` on a CLOSED lane and `[clear all]`).

## Reports

Report in the format of `../../references/report.md` after any lane changes section, when the user asks, and when you stop. The `display` skill opens the panel, or prints the same picture as text. After every lane change also run `bash "../../scripts/status.sh" --tokens` (it writes each lane agent's step into Herdr's sidebar), and `herdr plugin action invoke herdr-graph-engineering.graph.refresh` when the panel is installed.

Answers the user types in the panel's answer popup arrive here as a message starting `Answer for lane <lane>`: treat them exactly like an answer typed in this chat.

## Keep state outside the chat

This chat will be compacted. Anything you would need afterwards that Herdr, git and the lane files do not already show is written down **when it happens**, not later:

| Fact | Write it with |
| --- | --- |
| A standing answer or approval (new worktrees, folder trust, monorepo imports for lane worktrees, opencode folder access "Allow always", a kind for a role) | `bash "../../scripts/session.sh" add --list standing --text "<the answer, in the user's words>"` |
| A lane queued at the agent limit, with its prepared brief | `session.sh add --list queued --lane <lane> --repo <repo> --ref <brief file> --text "<idea>"`; when it starts: `session.sh del --list queued --lane <lane>` |
| A lane renamed | `session.sh add --list renames --lane <new> --text "<old> renamed to <new>"` |
| A user decision about the whole session; a scratch file or pull request not tied to a lane | `session.sh add --list notes --text ...` / `session.sh add --list files --ref <path or url> --text ...` |
| A done criterion beyond the pattern's ("done = merged to main and this window runs the new plugin version": reinstall, restart the panel, confirm) | `lane.sh done-extra --lane L --text "<criterion>"`; once checked: `lane.sh done-extra --lane L --met <n>`. A lane is done only when these are met too |
| A follow-up prompt sent to a node, scope added to a running lane, its brief or report path | `lane.sh note --lane L [--node N] [--ref <path>] --text "<what was sent or added>"` |

Remove what no longer holds (`session.sh del --list <list> --id <n>`). Never store a token, password or key: the scripts refuse text that looks like one; write where it lives (an environment variable's name, a file path) instead. `session.sh show` prints the file.

## Measuring

When the user asks how the lanes went overall, run `bash "../../scripts/measure.sh" --repo <dir>` for each repository and print it in a code block: per lane the outcome, minutes, retries, questions and failures; totals per pattern. Point out what stands out (a pattern that always needs the user, retries that run out) and let the user decide what to change.

## Rules

1. Patterns and roles decide the shape; scripts decide what is ready and what was recorded; you route, start, check and relay.
2. Never trust "done" from an agent: check the evidence, then record it.
3. Retry only through `lane.sh retry`. At the limit, ask.
4. Every question from an agent and every decision goes to the user, quoted exactly, labelled with lane and node.
5. Every lane-file write goes through `lane.sh`. Never edit a lane file by hand, never let a lane's agent touch it.
6. One writer per lane: never start two agents with write access in the same lane checkout.
7. A lane never starts another lane.
