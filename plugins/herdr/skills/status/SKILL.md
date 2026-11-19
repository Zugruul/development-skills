---
name: status
description: The on-demand status report for Herdr agents - read-only. For an agent that has taken the orchestrator role it prints the orchestrator report (its agents grouped into NEEDS YOU, WORKING and DONE, with their pull requests), then a short list of the other live agents and one of the repository's open worktrees; for any other agent it prints the same two lists for all live agents. Use for '/herdr:status', 'report on status', 'status report', 'how are the agents doing', 'what agents are running', 'which worktrees are open in herdr', 'is anything blocked'. Requires running inside Herdr.
allowed-tools: Bash
---

# Herdr status

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

This skill only reads. It never prompts, focuses, renames or closes anything.

```bash
python3 "../../scripts/herdr_ctl.py" overview                      # plain case: every live agent, then this repository's open worktrees
python3 "../../scripts/herdr_ctl.py" overview --mine <name> ...    # orchestrator case: the same, without you and the agents you follow
python3 "../../scripts/herdr_ctl.py" roster                        # the long form (pane, tab, directory), only when you need to place an agent
```

## The two lists

`overview` prints the live agents and the repository's worktrees ready-made. This is the one layout for both cases:

```text
Other agents (4)
  w1R  fix-harbor-vulnerabilities  claude    blocked
  w23  rest readiness warmup       claude    idle
  w2D  1k5a5ew4cde image input     claude    working  lane-1k5a5ew4cde
  wK   fix-converge-deps           opencode  working

Worktrees (3 open of 85)
  monorepo                    main
  fix-harbor-vulnerabilities  fix/harbor-vulnerabilities
  workflow-execute-js-api     feat/workflow-execute-js-api-internal  (no agent)
```

- **Agents:** workspace id, workspace label, kind, state, then the agent's name when it has one. The label is the title Herdr's sidebar shows for the workspace, so a row can be matched with the sidebar; it is printed in full and may contain spaces. Blocked agents come first, then by workspace. The heading is `Agents (n)` in the plain case, where your own row ends in `(this agent)`, and `Other agents (n)` with `--mine`.
- **Worktrees:** the heading counts the worktrees with an open Herdr workspace out of all the repository's worktrees. Only the open ones are listed, as workspace label and branch. The rest exist in git only and are not listed one by one.
- **Notes in parentheses** appear only for something unusual, such as `(no agent)` for an open workspace with no live agent.
- No paths, no pane or tab columns, no word for "unnamed". An unnamed agent's pane id is not in these lists: when you need it to target the agent, read it from `roster`.

**Paste the output of `overview` unchanged inside one fenced code block** (` ```text `). The columns are aligned with spaces, and outside a code block a Markdown renderer collapses them. Do not retype, re-sort, re-wrap or turn the lists into a table or bullets, and do not add paths or columns. The code fence is for these two lists only; the orchestrator report keeps its own rule and is never fenced.

## 1. Which case you are in

Decide from this conversation only. Both of these must be true for the **orchestrator case**:

1. **The role.** Earlier in this session you followed the `orchestrate` skill, or a skill that told you it makes you the orchestrator, and that is visible in your context (the skill's text, your own statement that you took the role, or an orchestrator report you already sent).
2. **Your agents.** You can list, from your context, the agents you started or were asked to follow: each one's name, as given when it was started, or as it appears in your last orchestrator report.

Everything else is the **plain case**. In particular:

- Your Herdr name being `orchestrator` (`name=` from `check`) is a hint that you held the role, never proof, and it says nothing about which agents are yours.
- A live agent is not yours because its name, workspace or branch looks like your work.

**When you cannot tell** (typically after your context was summarised: the role is only mentioned, or you no longer have the list of your agents), do not guess. Use the plain case and say so in one line before the lists, for example: `I may be the orchestrator here but no longer know which agents I started, so this is the plain list.` Then, if the list suggests you were orchestrating, ask the user which agents you should follow; once they answer, you are in the orchestrator case again with exactly those agents.

## 2. Orchestrator case

Print, in this order:

1. **The orchestrator report** for your agents, in the format of `../../references/report.md` exactly: grouped by state, with the `prs:` block and the color marks. Place every one of your agents by its state now (`roster`, then a look at its screen with the `listen` skill's `peek` for anything that is not plainly `working`). One of your agents that `roster` no longer lists is gone; the reference says where it goes.
2. **`Since last report`** works the same for an on-demand call as for any other report. Compare each agent's state now with your most recent orchestrator report in this conversation, whichever skill produced it:
   - there is one: one line per change, or `Since last report: nothing changed`;
   - this is your first report in this session: leave the line out;
   - you sent one earlier but it is no longer in your context: write `Since last report: unknown (the earlier report is no longer in my context)`. Never reconstruct old states from memory.
3. **The two lists**, after the report, as one fenced block: the output of `overview --mine <every agent you follow, by name or pane id>`. `Other agents (n)` holds every live agent that is not yours and not you; they are not part of the orchestrator report and get no section, dot or `prs:` block. `overview` leaves that list out when there are none, and always prints the worktrees.

A status call is a report like any other: it becomes the "last report" the next one is compared with.

## 3. Plain case

Print the output of `overview` (no `--mine`) as one fenced block: `Agents (n)` with every live agent, your own row marked `(this agent)`, then the worktrees. If any agent is `blocked`, say so in one line of prose after the block, naming each: they wait on a human.

No sections, no color marks and no `prs:` block here: those belong to the orchestrator report only.

States: `working` is mid-turn; `idle` and `done` are ready for input (`done` is a finished turn nobody has looked at yet); `blocked` waits at an approval or question; `unknown` means Herdr cannot classify the pane, which is not completion.

To see what one agent is doing, use the `listen` skill (`../listen/SKILL.md`). The lists cover this Herdr server only; agents on a saved SSH machine need the same commands with `herdr --machine <label>`.
