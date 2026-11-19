---
name: status
description: The on-demand status report for Herdr agents - read-only. For an agent that has taken the orchestrator role it prints the orchestrator report (its agents grouped into NEEDS YOU, WORKING and DONE, with their pull requests), then the other live agents and the repository's worktrees; for any other agent it prints the plain roster of live agents and worktrees. Use for '/herdr:status', 'report on status', 'status report', 'how are the agents doing', 'what agents are running', 'which worktrees are open in herdr', 'is anything blocked'. Requires running inside Herdr.
allowed-tools: Bash
---

# Herdr status

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

This skill only reads. It never prompts, focuses, renames or closes anything.

```bash
python3 "../../scripts/herdr_ctl.py" roster                       # every live agent on this Herdr server
python3 "../../scripts/herdr_ctl.py" roster --repo <primary checkout>   # only agents in that repository's workspaces
herdr worktree list --cwd "$PWD"                                  # this repository's worktrees; .open_workspace_id says which are open
```

## 1. Which case you are in

Decide from this conversation only. Both of these must be true for the **orchestrator case**:

1. **The role.** Earlier in this session you followed the `orchestrate` skill, or a skill that told you it makes you the orchestrator, and that is visible in your context (the skill's text, your own statement that you took the role, or an orchestrator report you already sent).
2. **Your agents.** You can list, from your context, the agents you started or were asked to follow: each one's name, as given when it was started, or as it appears in your last orchestrator report.

Everything else is the **plain case**. In particular:

- Your Herdr name being `orchestrator` (the `*` row of the roster, or `name=` from `check`) is a hint that you held the role, never proof, and it says nothing about which agents are yours.
- An agent on the roster is not yours because its name, workspace or branch looks like your work.

**When you cannot tell** (typically after your context was summarised: the role is only mentioned, or you no longer have the list of your agents), do not guess. Use the plain case and say so in one line before the roster, for example: `I may be the orchestrator here but no longer know which agents I started, so this is the plain roster.` Then, if the roster suggests you were orchestrating, ask the user which agents you should follow; once they answer, you are in the orchestrator case again with exactly those agents.

## 2. Orchestrator case

Print, in this order:

1. **The orchestrator report** for your agents, in the format of `../../references/report.md` exactly: grouped by state, with the `prs:` block and the color marks. Place every one of your agents by its state now (the roster, then a look at its screen with the `listen` skill's `peek` for anything that is not plainly `working`). One of your agents that is no longer on the roster is gone; the reference says where it goes.
2. **`Since last report`** works the same for an on-demand call as for any other report. Compare each agent's state now with your most recent orchestrator report in this conversation, whichever skill produced it:
   - there is one: one line per change, or `Since last report: nothing changed`;
   - this is your first report in this session: leave the line out;
   - you sent one earlier but it is no longer in your context: write `Since last report: unknown (the earlier report is no longer in my context)`. Never reconstruct old states from memory.
3. **Other live agents**: under a plain line `Other agents (n)`, every live agent on the roster that is not yours and not you, as in items 1 and 2 of the plain case (blocked first, then by workspace: name, kind, state, directory). They are not part of the orchestrator report and get no section, dot or `prs:` block. Leave the line out when there are none.
4. **The repository's worktrees**, as in item 3 of the plain case.

A status call is a report like any other: it becomes the "last report" the next one is compared with.

## 3. Plain case

Report:

1. **Blocked agents first**, each with its name (or pane id when unnamed), workspace and tab: they wait on a human.
2. Then the rest, grouped by workspace: name, kind, state, directory. Mark yourself (the `*` row).
3. The repository's worktrees: branch, path, and whether a workspace is open for each. A worktree with no `open_workspace_id` exists in git but is not shown in Herdr.

No sections, no color marks and no `prs:` block here: those belong to the orchestrator report only.

States: `working` is mid-turn; `idle` and `done` are ready for input (`done` is a finished turn nobody has looked at yet); `blocked` waits at an approval or question; `unknown` means Herdr cannot classify the pane, which is not completion.

To see what one agent is doing, use the `listen` skill (`../listen/SKILL.md`). The roster covers this Herdr server only; agents on a saved SSH machine need the same commands with `herdr --machine <label>`.
